# frozen_string_literal: true

require "fileutils"
require "pathname"
require "thor"

module Ithic
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    class_option :raiz, type: :string, desc: "Raíz del proyecto (default: directorio del repo)"

    desc "mapeos", "Lista los mapeos disponibles en config/mapeos"
    def mapeos
      con_manejo do
        nombres = configuracion.listar_mapeos
        if nombres.empty?
          puts "No hay mapeos en #{configuracion.mapeos_dir}"
        else
          nombres.each { |nombre| puts nombre }
        end
      end
    end

    desc "importar [CARPETA]", "Copia los .txt desde el origen a data/entrada/<mapeo>"
    option :origen, type: :string, desc: "Carpeta base de origen (default: ~/Downloads/pagares)"
    option :mapeo, type: :string, default: "pagares", desc: "Subcarpeta de destino en data/entrada"
    def importar(carpeta = nil)
      con_manejo do
        origen_base = Pathname.new(File.expand_path(options[:origen] || "~/Downloads/pagares"))
        raise ErrorIthic, "No existe el origen: #{origen_base}" unless origen_base.directory?

        if carpeta.nil?
          disponibles = origen_base.children.select(&:directory?).map { |ruta| ruta.basename.to_s }.sort
          puts "Uso: ithic importar CARPETA"
          puts "Carpetas disponibles: #{disponibles.empty? ? '(ninguna)' : disponibles.join(', ')}"
          exit(1)
        end

        origen = origen_base.join(carpeta)
        raise ErrorIthic, "No existe la carpeta: #{origen}" unless origen.directory?

        archivos = Dir.glob(origen.join("*.txt")).sort
        raise ErrorIthic, "No hay archivos .txt en #{origen}" if archivos.empty?

        destino = configuracion.entrada_dir.join(options[:mapeo])
        FileUtils.mkdir_p(destino)
        Dir.glob(destino.join("*.txt")).each { |viejo| File.unlink(viejo) }

        archivos.each do |archivo|
          FileUtils.copy_file(archivo, destino.join(File.basename(archivo)))
          puts "Copiado: #{File.basename(archivo)}"
        end
        puts "\n#{archivos.size} archivo(s) copiado(s) a #{destino}"
      end
    end

    desc "consultar MAPEO", "Ejecuta la consulta DSM del mapeo y muestra el total de registros"
    option :param, type: :array, default: [], banner: "NOMBRE=VALOR", desc: "Parámetros de la consulta"
    def consultar(nombre_mapeo)
      con_manejo do
        mapeo = cargar_mapeo(nombre_mapeo)
        valores = resolver_parametros(mapeo)
        base_datos = BaseDatos.desde(configuracion)
        begin
          sql, argumentos = mapeo.sql_con_valores(valores)
          filas = base_datos.consultar(sql, argumentos)
        ensure
          base_datos.cerrar
        end
        puts "#{filas.size} registros para #{resumen_parametros(valores)}"
      end
    end

    desc "comparar MAPEO ARCHIVO", "Compara un .txt de ITHIC contra DSM y genera reportes Markdown"
    option :param, type: :array, default: [], banner: "NOMBRE=VALOR", desc: "Parámetros de la consulta"
    def comparar(nombre_mapeo, archivo)
      con_manejo do
        mapeo = cargar_mapeo(nombre_mapeo)
        ruta = resolver_archivo(archivo)
        valores = resolver_parametros(mapeo, ruta)
        fuente = LectorTxt.leer(ruta)

        base_datos = BaseDatos.desde(configuracion)
        begin
          sql, argumentos = mapeo.sql_con_valores(valores)
          filas_dsm = base_datos.consultar(sql, argumentos)
        ensure
          base_datos.cerrar
        end

        resultado = Comparador.new(mapeo, fuente, filas_dsm).comparar
        destino = configuracion.reportes_dir.join(mapeo.reporte_carpeta)
        reporte = ReporteMarkdown.new(
          mapeo, resultado, fuente: fuente, parametros: valores, destino: destino
        )
        reporte.escribir!

        imprimir_comparacion(fuente, resultado, reporte)
      end
    end

    desc "migrar MAPEO ARCHIVO", "Genera (y opcionalmente ejecuta) INSERTs en DSM desde un .txt de ITHIC"
    option :param, type: :array, default: [], banner: "NOMBRE=VALOR", desc: "Parámetros de la consulta"
    option :ejecutar, type: :boolean, default: false, desc: "Aplica las sentencias en una transacción"
    option :sql, type: :string, desc: "Escribe el script SQL generado en la ruta indicada"
    option :conflicto, type: :string, banner: "nada|actualizar", desc: "Política ON CONFLICT"
    def migrar(nombre_mapeo, archivo)
      con_manejo do
        mapeo = cargar_mapeo(nombre_mapeo)
        raise ErrorMapeo, "El mapeo #{mapeo.nombre} no define una sección migracion" unless mapeo.migracion

        ruta = resolver_archivo(archivo)
        fuente = LectorTxt.leer(ruta)

        base_datos = BaseDatos.desde(configuracion)
        begin
          repositorio = RepositorioDsm.new(base_datos)
          migrador = Migrador.new(
            mapeo, fuente: fuente, repositorio: repositorio, conflicto: options[:conflicto]
          )
          plan = migrador.plan
          sentencias = migrador.sentencias
          imprimir_plan(mapeo, fuente, plan, sentencias.size)

          if options[:sql]
            File.write(options[:sql], migrador.script_sql, encoding: "UTF-8")
            puts "SQL generado: #{options[:sql]}"
          end

          if options[:ejecutar]
            repositorio.ejecutar_sentencias(sentencias)
            puts "#{sentencias.size} sentencia(s) ejecutada(s) en DSM"
          else
            imprimir_muestra(sentencias)
            puts "Simulación: no se ejecutó nada. Usa --ejecutar para aplicar los cambios."
          end
        ensure
          base_datos.cerrar
        end
      end
    end

    no_commands do
      def con_manejo
        yield
      rescue ErrorIthic => e
        puts "Error: #{e.message}"
        exit(1)
      rescue PG::Error => e
        puts "Error de base de datos: #{e.message}"
        exit(1)
      rescue SystemCallError => e
        puts "Error de archivos: #{e.message}"
        exit(1)
      end

      def configuracion
        @configuracion ||= Configuracion.new(raiz: options[:raiz] || Ithic::RAIZ)
      end

      def cargar_mapeo(nombre)
        ruta = configuracion.ruta_mapeo(nombre)
        unless ruta
          raise ErrorMapeo, "No se encontró el mapeo '#{nombre}'. Usa `ithic mapeos` para ver los disponibles"
        end

        Mapeo.cargar(ruta)
      end

      def resolver_archivo(archivo)
        candidatos = [Pathname.new(archivo)]
        candidatos.concat(Dir.glob(configuracion.entrada_dir.join("**", archivo)).map { |r| Pathname.new(r) })
        candidatos.find(&:file?) ||
          raise(ErrorIthic, "No existe el archivo: #{archivo} (búscalo con `ithic importar`)")
      end

      def resolver_parametros(mapeo, archivo = nil)
        valores = archivo ? mapeo.parametros_desde_archivo(File.basename(archivo)) : {}
        Array(options[:param]).each do |par|
          nombre, separador, valor = par.partition("=")
          if separador.empty? || nombre.empty?
            raise ErrorMapeo, "Formato de --param inválido: #{par} (usa NOMBRE=VALOR)"
          end

          valores[nombre.to_sym] = mapeo.convertir_parametro(nombre, valor)
        end

        faltantes = mapeo.parametros.map(&:nombre) - valores.keys
        raise ErrorMapeo, "Faltan parámetros: #{faltantes.join(', ')} (usa --param #{faltantes.first}=VALOR)" if faltantes.any?

        valores
      end

      def resumen_parametros(valores)
        valores.map { |nombre, valor| "#{nombre}=#{valor}" }.join(", ")
      end

      def imprimir_comparacion(fuente, resultado, reporte)
        puts "Archivo: #{fuente.ruta.basename} (#{resultado.total_fuente} registros)"
        puts "DSM: #{resultado.total_dsm} registros | solo en ITHIC: #{resultado.solo_fuente} | " \
             "solo en DSM: #{resultado.solo_dsm}"
        puts "Resultado: #{resultado.cuadra? ? 'CUADRA' : 'NO CUADRA'}"

        unless resultado.campos_faltantes.empty?
          puts "Campos ausentes en ITHIC, se omiten: #{resultado.campos_faltantes.map(&:fuente).join(', ')}"
        end

        if resultado.diferencias.empty?
          puts "Sin diferencias"
        else
          resultado.campos_comparados.each do |campo|
            filas = resultado.diferencias_por_campo(campo.fuente)
            next if filas.empty?

            puts "#{campo.fuente}: #{filas.size} fila(s) de diferencia -> #{reporte.ruta_campo(campo)}"
          end
        end
        puts "Resumen: #{reporte.nombre_resumen}"
      end

      def imprimir_plan(mapeo, fuente, plan, total_sentencias)
        puts "Plan de migración: #{mapeo.nombre} -> #{plan.tabla}"
        puts "Archivo: #{fuente.ruta.basename}"
        puts "Registros en archivo: #{plan.total}"
        puts "Ya existen en DSM: #{plan.total_existentes}"
        puts "Faltantes por insertar: #{plan.total_faltantes}"
        puts "Conflicto: #{plan.conflicto}#{plan.conflicto == 'nada' ? ' (no actualiza registros existentes)' : ''}"
        puts "Sentencias a ejecutar: #{total_sentencias}"
      end

      def imprimir_muestra(sentencias)
        return if sentencias.empty?

        puts ""
        puts "Muestra de sentencias:"
        sentencias.first(3).each_with_index do |sentencia, indice|
          puts "#{indice + 1}. #{sentencia.sql}"
          puts "   valores: #{sentencia.valores.map { |valor| valor_muestra(valor) }.join(', ')}"
        end
      end

      def valor_muestra(valor)
        valor.is_a?(BigDecimal) ? valor.to_s("F") : valor.inspect
      end
    end
  end
end
