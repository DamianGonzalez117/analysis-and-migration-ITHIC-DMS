# frozen_string_literal: true

require "bigdecimal"
require "yaml"

module Ithic
  class Mapeo
    Parametro = Struct.new(:nombre, :tipo, :desde_nombre, :sumar, keyword_init: true)
    Campo = Struct.new(:fuente, :dsm, :tipo, keyword_init: true)
    Clave = Struct.new(:fuente, :dsm, :tipo, keyword_init: true)
    ColumnaMigracion = Struct.new(:fuente, :columna, :tipo, :opcional, keyword_init: true)
    ClaveMigracion = Struct.new(:fuente, :columna, :tipo, keyword_init: true)
    Migracion = Struct.new(:tabla, :clave, :columnas, :conflicto, keyword_init: true) do
      def columnas_requeridas
        columnas.reject(&:opcional).map(&:fuente)
      end
    end

    def self.cargar(ruta)
      ruta = Pathname.new(ruta)
      raise ErrorMapeo, "No existe el mapeo: #{ruta}" unless ruta.file?

      datos = YAML.safe_load_file(ruta, aliases: true)
      new(datos, ruta: ruta)
    rescue Psych::SyntaxError => e
      raise ErrorMapeo, "YAML inválido en #{ruta}: #{e.message}"
    end

    def self.desde_hash(datos)
      new(datos)
    end

    attr_reader :ruta

    def initialize(datos, ruta: nil)
      @datos = datos || {}
      @ruta = ruta
      @parametros = construir_parametros
      @campos = construir_campos
      @clave = construir_clave
      @migracion = construir_migracion
      validar!
    end

    def nombre
      @datos["nombre"] || (ruta && File.basename(ruta.to_s, ".yml")) || "mapeo"
    end

    def descripcion
      @datos["descripcion"].to_s
    end

    def parametros
      @parametros
    end

    def campos
      @campos
    end

    def clave
      @clave
    end

    def consulta
      @datos["consulta"].to_s
    end

    def migracion
      @migracion
    end

    def reporte_carpeta
      (@datos.dig("reporte", "carpeta") || nombre).to_s
    end

    def reporte_sufijo
      @datos.dig("reporte", "sufijo")&.to_s
    end

    def parametros_desde_archivo(nombre_archivo)
      parametros.each_with_object({}) do |parametro, valores|
        next unless parametro.desde_nombre

        coincidencia = Regexp.new(parametro.desde_nombre).match(nombre_archivo.to_s)
        next unless coincidencia

        bruto = coincidencia[1] || coincidencia[0]
        valores[parametro.nombre] = convertir(parametro, bruto)
      end
    end

    def convertir_parametro(nombre, valor)
      parametro = parametros.find { |candidato| candidato.nombre == nombre.to_sym }
      raise ErrorMapeo, "Parámetro desconocido: #{nombre}" unless parametro

      convertir(parametro, valor)
    end

    def sql_con_valores(valores)
      orden = []
      nombre_mapeo = nombre
      sql = consulta.gsub(/(?<![:\w]):([a-zA-Z_][a-zA-Z0-9_]*)/) do
        parametro = Regexp.last_match(1).to_sym
        unless valores.key?(parametro)
          raise ErrorMapeo, "Falta el valor del parámetro :#{parametro} para el mapeo #{nombre_mapeo}"
        end

        orden << valores[parametro]
        "$#{orden.size}"
      end
      [sql, orden]
    end

    private

    def construir_parametros
      Array(@datos["parametros"]).map do |parametro|
        Parametro.new(
          nombre: parametro["nombre"].to_s.to_sym,
          tipo: (parametro["tipo"] || "texto").to_s.to_sym,
          desde_nombre: parametro["desde_nombre"],
          sumar: parametro["sumar"]
        )
      end
    end

    def construir_campos
      Array(@datos["campos"]).map do |campo|
        Campo.new(
          fuente: campo["fuente"].to_s,
          dsm: (campo["dsm"] || campo["fuente"]).to_s,
          tipo: (campo["tipo"] || "texto").to_s.to_sym
        )
      end
    end

    def construir_clave
      clave = @datos["clave"] || {}
      Clave.new(
        fuente: clave["fuente"].to_s,
        dsm: (clave["dsm"] || clave["fuente"]).to_s,
        tipo: (clave["tipo"] || "texto").to_s.to_sym
      )
    end

    def construir_migracion
      datos = @datos["migracion"]
      return nil unless datos

      clave = datos["clave"] || {}
      Migracion.new(
        tabla: datos["tabla"].to_s,
        clave: ClaveMigracion.new(
          fuente: clave["fuente"].to_s,
          columna: clave["columna"].to_s,
          tipo: (clave["tipo"] || "texto").to_s.to_sym
        ),
        columnas: Array(datos["columnas"]).map do |columna|
          ColumnaMigracion.new(
            fuente: columna["fuente"].to_s,
            columna: columna["columna"].to_s,
            tipo: (columna["tipo"] || "texto").to_s.to_sym,
            opcional: columna["opcional"] ? true : false
          )
        end,
        conflicto: (datos["conflicto"] || "nada").to_s
      )
    end

    def validar!
      raise ErrorMapeo, "El mapeo #{nombre} no define la sección clave" if clave.fuente.empty?
      raise ErrorMapeo, "El mapeo #{nombre} no define campos por comparar" if campos.empty?
      raise ErrorMapeo, "El mapeo #{nombre} no define la consulta DSM" if consulta.empty?
    end

    def convertir(parametro, valor)
      convertido =
        case parametro.tipo
        when :entero
          Integer(valor.to_s)
        when :decimal
          BigDecimal(valor.to_s)
        else
          valor.to_s
        end
      if parametro.sumar && convertido.is_a?(Integer) && convertido < 100
        convertido + parametro.sumar
      else
        convertido
      end
    rescue ArgumentError
      raise ErrorMapeo, "Valor inválido para el parámetro #{parametro.nombre}: #{valor.inspect}"
    end
  end
end
