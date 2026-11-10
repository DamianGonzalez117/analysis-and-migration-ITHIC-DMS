#!/usr/bin/env ruby
# frozen_string_literal: true

# Inserta en DSM los catálogos usados por los consumos, en este orden:
# cat_accounting_record_types, cat_cost_center_consumption, cat_sales_types
# y cat_sales_details_types.
#
# - Omite registros cuyo external_id ya existe. En cat_sales_details_types
#   se compara por external_id y, si la fila aún no lo tiene, por nombre
#   (se conserva la comparación por cantidad de nombres repetidos).
# - Los registros nuevos usan object_status ACTIVO.
# - cat_cost_center_consumption resuelve cat_accounting_record_type_id con
#   el external_id del catálogo de registros contables.
# - --actualizar corrige los campos de filas existentes; en
#   cat_sales_details_types rellena el external_id de las filas que lo
#   tengan vacío (no sobrescribe valores ya asignados).
#
# Uso:
#   bundle exec ruby scripts/migracion_consumos/insertar_catalogos.rb
#   bundle exec ruby scripts/migracion_consumos/insertar_catalogos.rb --ejecutar
#   bundle exec ruby scripts/migracion_consumos/insertar_catalogos.rb --actualizar --ejecutar
#   bundle exec ruby scripts/migracion_consumos/insertar_catalogos.rb --sql catalogos.sql

require "optparse"
require_relative "comun"

module MigracionConsumos
  module InsertadorCatalogos
    extend MigracionConsumos

    OBJECT_STATUS_ACTIVO = "01905186-4ff0-7041-93a3-404eff394ff9"

    ART = {
      clave: :art,
      tabla: "cat_accounting_record_types",
      id: "cat_accounting_record_type_id",
      columnas: %w[cat_accounting_record_type_id external_id name short_name description object_status_id created_by],
      actualizables: %w[name short_name description]
    }.freeze

    CCE = {
      clave: :cce,
      tabla: "cat_cost_center_consumption",
      id: "cat_cost_center_consumption_id",
      columnas: %w[cat_cost_center_consumption_id external_id name short_name description cost_center
                   cat_accounting_record_type_id document_class object_status_id created_by],
      actualizables: %w[name short_name description cost_center cat_accounting_record_type_id document_class]
    }.freeze

    ST = {
      clave: :sales_type,
      tabla: "cat_sales_types",
      id: "cat_sale_type_id",
      columnas: %w[cat_sale_type_id external_id name long_name short_name description object_status_id created_by],
      actualizables: %w[name long_name short_name description]
    }.freeze

    SD = {
      clave: :sales_details,
      tabla: "cat_sales_details_types",
      id: "cat_sale_detail_type_id",
      columnas: %w[cat_sale_detail_type_id external_id name short_name description object_status_id created_by],
      actualizables: %w[external_id]
    }.freeze

    def self.ejecutar(argv)
      opciones = parsear_opciones(argv)
      base = conexion
      begin
        art = preparar_art(base, opciones)
        planes = [art, preparar_cce(base, art[:por_codigo], opciones), preparar_st(base, opciones), preparar_sd(base, opciones)]

        resumen(planes, opciones)
        escribir_sql(planes, opciones[:sql]) if opciones[:sql]

        if opciones[:ejecutar]
          planes.each { |plan| aplicar(base, plan, opciones[:lote]) }
          puts "\nCatálogos insertados/actualizados."
          puts "Ejecuta generar_mapa.rb para refrescar mapa_catalogos.json."
        else
          puts "\nSimulación: no se ejecutó nada. Usa --ejecutar para insertar."
        end
      ensure
        base.cerrar
      end
      0
    end

    def self.parsear_opciones(argv)
      opciones = { ejecutar: false, actualizar: false, lote: 250, sql: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Uso: bundle exec ruby scripts/migracion_consumos/insertar_catalogos.rb [opciones]"
        opts.on("--ejecutar", "Aplica los INSERT/UPDATE (por defecto solo simula)") { opciones[:ejecutar] = true }
        opts.on("--actualizar", "Corrige los campos de registros existentes") { opciones[:actualizar] = true }
        opts.on("--lote N", Integer, "Registros por sentencia INSERT (default 250)") { |valor| opciones[:lote] = valor }
        opts.on("--sql RUTA", "Escribe el SQL generado con literales") { |valor| opciones[:sql] = valor }
        opts.on("-h", "--help", "Muestra esta ayuda") do
          puts opts
          exit(0)
        end
      end
      parser.parse(argv)
      opciones
    end

    def self.preparar_art(base, opciones)
      _, filas = leer_catalogo("cat_accounting_record_types.txt")
      registros = filas.map do |fila|
        valores = {
          "cat_accounting_record_type_id" => SecureRandom.uuid,
          "external_id" => entero(fila["EXTERNAL_ID"]),
          "name" => texto(fila["NAME"]),
          "short_name" => texto(fila["SHORT_NAME"]),
          "description" => texto(fila["DESCRIPTION"]),
          "object_status_id" => OBJECT_STATUS_ACTIVO,
          "created_by" => CREADO_POR
        }
        { clave: normalizar_codigo(fila["EXTERNAL_ID"]), id: valores["cat_accounting_record_type_id"], valores: valores }
      end

      existentes = existentes_por_codigo(base, ART)
      plan = planificar(ART, registros, existentes, opciones[:actualizar])
      plan[:por_codigo] = existentes.transform_values { |fila| fila[:id] }
      plan[:nuevos].each { |registro| plan[:por_codigo][registro[:clave]] = registro[:id] }
      plan
    end

    def self.preparar_cce(base, art_por_codigo, opciones)
      incidencias = []
      existentes = existentes_por_codigo(base, CCE)

      registros = filas_cce(incidencias).map do |fila|
        codigo_art = normalizar_codigo(fila["EXTERNAL_CAT_ACCOUNTING_RECORD_TYPES"])
        art_id = codigo_art.empty? ? nil : art_por_codigo[codigo_art]
        if art_id.nil? && !codigo_art.empty?
          incidencias << [fila["EXTERNAL_ID"], "art_no_existe", codigo_art]
        end

        valores = {
          "cat_cost_center_consumption_id" => SecureRandom.uuid,
          "external_id" => texto(fila["EXTERNAL_ID"]),
          "name" => texto(fila["NAME"]),
          "short_name" => texto(fila["SHOR_NAME"]),
          "description" => texto(fila["DESCRIPTION"]),
          "cost_center" => texto(fila["COST_CENTER"]),
          "cat_accounting_record_type_id" => art_id,
          "document_class" => texto(fila["DOCUMENT_CLASS"]),
          "object_status_id" => OBJECT_STATUS_ACTIVO,
          "created_by" => CREADO_POR
        }
        { clave: normalizar_codigo(fila["EXTERNAL_ID"]), id: valores["cat_cost_center_consumption_id"], valores: valores }
      end

      planificar(CCE, registros, existentes, opciones[:actualizar]).merge(incidencias: incidencias)
    end

    def self.preparar_st(base, opciones)
      _, filas = leer_catalogo("cat_sales_types.txt")
      registros = filas.map do |fila|
        valores = {
          "cat_sale_type_id" => SecureRandom.uuid,
          "external_id" => texto(fila["EXTERNAL_ID"]),
          "name" => texto(fila["NAME"]),
          "long_name" => texto(fila["LONG_NAME"]),
          "short_name" => nil,
          "description" => texto(fila["DESCRIPITON"]),
          "object_status_id" => OBJECT_STATUS_ACTIVO,
          "created_by" => CREADO_POR
        }
        { clave: normalizar_codigo(fila["EXTERNAL_ID"]), id: valores["cat_sale_type_id"], valores: valores }
      end

      planificar(ST, registros, existentes_por_codigo(base, ST), opciones[:actualizar])
    end

    def self.preparar_sd(base, opciones)
      _, filas = leer_catalogo("cat_sales_details_types.txt")
      con_external_id = columna_external_id?(base, SD[:tabla])
      columnas = con_external_id ? SD[:columnas] : SD[:columnas] - %w[external_id]
      existentes = existentes_sd(base, con_external_id)

      por_nombre = existentes.group_by { |fila| normalizar_nombre(fila["NAME"]) }
      por_external_id = existentes.each_with_object({}) do |fila, mapa|
        clave = normalizar_codigo(fila["EXTERNAL_ID"])
        mapa[clave] ||= fila unless clave.empty?
      end
      nuevos = []
      actualizaciones = []
      omitidos = 0
      diferencias = 0

      filas.group_by { |fila| normalizar_nombre(fila["NAME"]) }.each do |nombre, grupo|
        pendientes = grupo.dup
        candidatos = (por_nombre[nombre] || [])
                     .partition { |candidato| candidato["EXTERNAL_ID"].to_s.strip.empty? }
                     .flatten

        pendientes.reject! do |fila|
          external_id = normalizar_codigo(fila["EXTERNAL_ID"])
          actual = external_id.empty? ? nil : por_external_id[external_id]
          next false if actual.nil?

          indice = candidatos.index { |candidato| candidato["ID"] == actual["ID"] }
          candidatos.delete_at(indice) if indice
          omitidos += 1
          true
        end

        pendientes.each do |fila|
          actual = candidatos.shift
          if actual
            omitidos += 1
            next unless con_external_id

            external_id = texto(fila["EXTERNAL_ID"])
            next if external_id.nil? || !normalizar_codigo(actual["EXTERNAL_ID"]).empty?

            diferencias += 1
            actualizaciones << { id: actual["ID"], cambios: { "external_id" => external_id } } if opciones[:actualizar]
            next
          end

          valores = {
            "cat_sale_detail_type_id" => SecureRandom.uuid,
            "name" => texto(fila["NAME"]),
            "short_name" => texto(fila["SHORT_NAME"]),
            "description" => texto(fila["LONG_NAME"]),
            "object_status_id" => OBJECT_STATUS_ACTIVO,
            "created_by" => CREADO_POR
          }
          valores["external_id"] = texto(fila["EXTERNAL_ID"]) if con_external_id
          nuevos << { clave: nombre, id: valores["cat_sale_detail_type_id"], valores: valores }
        end
      end

      { clave: SD[:clave], tabla: SD[:tabla], id: SD[:id], columnas: columnas,
        nuevos: nuevos, actualizaciones: actualizaciones, omitidos: omitidos, diferencias: diferencias,
        incidencias: [] }
    end

    def self.existentes_sd(base, con_external_id)
      external_id = con_external_id ? "external_id::text" : "NULL::text"
      base.consultar(<<~SQL)
        SELECT #{Ithic::Sql.identificador(SD[:id])}::text AS id,
               #{external_id} AS external_id,
               name
        FROM #{Ithic::Sql.identificador(SD[:tabla])}
        WHERE name IS NOT NULL
        ORDER BY created_at, #{Ithic::Sql.identificador(SD[:id])}
      SQL
    end

    def self.columna_external_id?(base, tabla)
      base.consultar(<<~SQL).any?
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = ANY (current_schemas(false))
          AND table_name = #{Ithic::Sql.literal(tabla)}
          AND column_name = 'external_id'
        LIMIT 1
      SQL
    end

    def self.filas_cce(incidencias)
      lineas = leer_texto(File.join(DIR_CONSUMOS, "cat_cost_center_consumption.txt"))
               .split(/\r?\n/).reject { |linea| linea.strip.empty? }
      encabezado = lineas.shift.split("|", -1).map(&:strip)
      filas = []
      indice = 0

      while indice < lineas.size
        partes = lineas[indice].split("|", -1)
        if partes.size == encabezado.size - 2
          siguiente = lineas[indice + 1].to_s.split("|", -1)
          if siguiente.size == 3 && partes[4].to_s.start_with?(siguiente[0].to_s)
            partes = partes[0, 4] + [siguiente[0], siguiente[1], siguiente[2]]
            indice += 1
          end
        end

        if partes.size == encabezado.size
          filas << encabezado.zip(partes).to_h { |clave, valor| [clave, valor.to_s.strip] }
        else
          incidencias << [partes.first.to_s.strip, "fila_malformada", partes.size]
        end
        indice += 1
      end

      filas
    end

    def self.existentes_por_codigo(base, config)
      filas = base.consultar(<<~SQL)
        SELECT #{Ithic::Sql.identificador(config[:id])}::text AS id,
               external_id::text AS clave,
               #{config[:actualizables].map { |columna| Ithic::Sql.identificador(columna) }.join(", ")}
        FROM #{Ithic::Sql.identificador(config[:tabla])}
        WHERE external_id IS NOT NULL
        ORDER BY created_at, #{Ithic::Sql.identificador(config[:id])}
      SQL

      filas.each_with_object({}) do |fila, existentes|
        clave = normalizar_codigo(fila["CLAVE"])
        next if clave.empty?

        existentes[clave] ||= {
          id: fila["ID"],
          valores: config[:actualizables].to_h { |columna| [columna, fila[columna.upcase]] }
        }
      end
    end

    def self.planificar(config, registros, existentes, actualizar)
      nuevos = []
      actualizaciones = []
      omitidos = 0
      diferencias = 0

      registros.each do |registro|
        actual = existentes[registro[:clave]]
        if actual.nil?
          nuevos << registro
          next
        end

        omitidos += 1
        cambios = config[:actualizables].each_with_object({}) do |columna, acumulados|
          valor = registro[:valores][columna]
          acumulados[columna] = valor if valor.to_s != actual[:valores][columna].to_s
        end
        next if cambios.empty?

        diferencias += 1
        actualizaciones << { id: actual[:id], cambios: cambios } if actualizar
      end

      { clave: config[:clave], tabla: config[:tabla], id: config[:id], columnas: config[:columnas],
        nuevos: nuevos, actualizaciones: actualizaciones, omitidos: omitidos, diferencias: diferencias,
        incidencias: [] }
    end

    def self.texto(valor)
      limpio = valor.to_s.strip
      limpio.empty? ? nil : limpio
    end

    def self.normalizar_codigo(valor)
      valor.to_s.strip.sub(/\.0+\z/, "")
    end

    def self.normalizar_nombre(valor)
      valor.to_s.strip.downcase
    end

    def self.resumen(planes, opciones)
      puts "Catálogos de consumos:"
      planes.each do |plan|
        linea = format("  %-32s leídos=%3d nuevos=%3d existentes=%3d",
                       plan[:tabla], plan[:nuevos].size + plan[:omitidos], plan[:nuevos].size, plan[:omitidos])
        linea += if opciones[:actualizar]
                   format(" actualizar=%3d", plan[:actualizaciones].size)
                 else
                   format(" con_diferencias=%3d", plan[:diferencias])
                 end
        puts linea
        plan[:incidencias].first(5).each { |fila| puts "    incidencia: #{fila.join(' | ')}" }
      end

      con_diferencias = planes.sum { |plan| plan[:diferencias] }
      return if opciones[:actualizar] || con_diferencias.zero?

      puts "  Hay #{con_diferencias} fila(s) existente(s) con datos distintos; usa --actualizar para corregirlas."
    end

    def self.escribir_sql(planes, ruta)
      File.open(ruta, "w") do |archivo|
        archivo.puts "-- Generado por insertar_catalogos.rb"
        planes.each do |plan|
          columnas = plan[:columnas].map { |columna| Ithic::Sql.identificador(columna) }.join(", ")
          plan[:nuevos].each do |registro|
            literales = plan[:columnas].map { |columna| Ithic::Sql.literal(registro[:valores][columna]) }
            archivo.puts "INSERT INTO #{Ithic::Sql.identificador(plan[:tabla])} (#{columnas}) " \
                         "VALUES (#{literales.join(', ')});"
          end
          plan[:actualizaciones].each do |actualizacion|
            cambios = actualizacion[:cambios].map do |columna, valor|
              "#{Ithic::Sql.identificador(columna)} = #{Ithic::Sql.literal(valor)}"
            end
            archivo.puts "UPDATE #{Ithic::Sql.identificador(plan[:tabla])} SET #{cambios.join(', ')}, " \
                         "updated_at = now() WHERE #{Ithic::Sql.identificador(plan[:id])} = " \
                         "#{Ithic::Sql.literal(actualizacion[:id])};"
          end
        end
      end
      puts "\nSQL generado: #{ruta} (#{planes.sum { |plan| plan[:nuevos].size }} INSERT, " \
           "#{planes.sum { |plan| plan[:actualizaciones].size }} UPDATE)"
    end

    def self.aplicar(base, plan, tamano_lote)
      plan[:nuevos].each_slice(tamano_lote) do |lote|
        base.conexion.transaction do
          columnas = plan[:columnas].map { |columna| Ithic::Sql.identificador(columna) }.join(", ")
          grupos = lote.each_index.map do |indice|
            inicio = indice * plan[:columnas].size
            "(#{(1..plan[:columnas].size).map { |posicion| "$#{inicio + posicion}" }.join(', ')})"
          end
          valores = lote.flat_map { |registro| plan[:columnas].map { |columna| registro[:valores][columna] } }
          base.ejecutar("INSERT INTO #{Ithic::Sql.identificador(plan[:tabla])} (#{columnas}) " \
                        "VALUES #{grupos.join(', ')}", valores)
        end
      end

      plan[:actualizaciones].each do |actualizacion|
        cambios = actualizacion[:cambios]
        asignaciones = cambios.keys.each_with_index.map { |columna, indice| "#{Ithic::Sql.identificador(columna)} = $#{indice + 1}" }
        base.ejecutar("UPDATE #{Ithic::Sql.identificador(plan[:tabla])} SET #{asignaciones.join(', ')}, " \
                      "updated_at = now() WHERE #{Ithic::Sql.identificador(plan[:id])} = $#{cambios.size + 1}",
                      cambios.values + [actualizacion[:id]])
      end

      puts "  #{plan[:tabla]}: #{plan[:nuevos].size} insertado(s), #{plan[:actualizaciones].size} actualizado(s)"
    end
  end
end

exit(MigracionConsumos::InsertadorCatalogos.ejecutar(ARGV))
