#!/usr/bin/env ruby
# frozen_string_literal: true

# Inserta los consumos de consumption_blocked_details.txt en DSM.
#
# Reglas:
# - Si el external_id ya existe en DSM, el registro se omite. Con
#   --actualizar se rellenan sus cat_*_id que estén en NULL.
# - Registros nuevos reciben un consumption_blocked_details_id generado.
# - object_status_id = CREADO (1f0746ed-9ae6-4055-a641-efb4bf7d0a56) salvo
#   que OBJECT_STATUS_POR_REGISTRO indique uno de los estatus válidos.
# - Los UUID de catálogos se resuelven con mapa_catalogos.json (generar_mapa.rb).
# - Si la distribución referenciada no existe en DSM, se inserta con NULL.
# - Booleanos: "1" => true; vacío o "0" => false.
# - Fechas d/m/YYYY -> date; campos vacíos -> NULL.
#
# Uso:
#   bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb                # simulación
#   bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --limite 10 --ejecutar
#   bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --actualizar --ejecutar
#   bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --sql salida.sql
#   bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb --reporte incidencias.csv --ejecutar

require "csv"
require "optparse"
require_relative "comun"

module MigracionConsumos
  module Insertador
    extend MigracionConsumos

    TABLA = "consumption_blocked_details"
    COLUMNAS = %w[
      consumption_blocked_details_id
      contract_investment_distribution_id
      cat_cost_center_consumption_id
      cce_number
      amount
      sap_send
      comments
      object_status_id
      cat_accounting_record_type_id
      cat_sale_type_id
      business_areas_id
      consumption_date
      cost_amout
      cat_sale_detail_type_id
      document_class
      otj_key
      is_complement
      program_id
      cost_cc
      upload_key
      upload_consecutive
      original_date
      sub_production
      external_id
    ].freeze

    def self.ejecutar(argv)
      opciones = parsear_opciones(argv)
      mapa = cargar_mapa
      registros, anomalias = parsear_consumos

      if registros.empty?
        puts "No se pudieron leer registros de #{RUTA_CONSUMOS}"
        return 1
      end

      base = conexion
      begin
        existentes = external_ids_existentes(base)
        nuevos_todos = registros.reject { |fila| existentes.include?(normalizar_external_id(fila["EXTENAL_ID"])) }
        nuevos = opciones[:limite] ? nuevos_todos.first(opciones[:limite]) : nuevos_todos

        distribuciones = distribuciones_existentes(base, nuevos)
        programas = programas_existentes(base, nuevos)

        valores, incidencias = construir_registros(nuevos, mapa, distribuciones, programas)

        actualizaciones = []
        incidencias_actualizacion = []
        if opciones[:actualizar]
          existentes_todos = registros.select { |fila| existentes.include?(normalizar_external_id(fila["EXTENAL_ID"])) }
          existentes_actualizar = opciones[:limite] ? existentes_todos.first(opciones[:limite]) : existentes_todos
          actualizaciones, incidencias_actualizacion = construir_actualizaciones(existentes_actualizar, mapa)
          incidencias += incidencias_actualizacion
        end

        resumen(registros, anomalias, nuevos_todos, valores, incidencias, opciones, actualizaciones)
        escribir_reporte(incidencias, opciones[:reporte]) if opciones[:reporte]
        escribir_sql(valores, actualizaciones, opciones[:sql]) if opciones[:sql]

        if opciones[:ejecutar]
          insertar(base, valores, opciones[:lote])
          puts "\n#{valores.size} registro(s) insertado(s) en #{TABLA}"
          actualizar(base, actualizaciones, opciones[:lote]) if opciones[:actualizar] && !actualizaciones.empty?
        else
          puts "\nSimulación: no se ejecutó nada. Usa --ejecutar para insertar."
        end
      ensure
        base.cerrar
      end
      0
    end

    def self.parsear_opciones(argv)
      opciones = { ejecutar: false, actualizar: false, limite: nil, lote: 250, sql: nil, reporte: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Uso: bundle exec ruby scripts/migracion_consumos/insertar_consumos.rb [opciones]"
        opts.on("--ejecutar", "Aplica los INSERT (por defecto solo simula)") { opciones[:ejecutar] = true }
        opts.on("--actualizar", "Rellena los cat_*_id NULL de registros existentes") { opciones[:actualizar] = true }
        opts.on("--limite N", Integer, "Procesa solo los primeros N registros nuevos/actualizaciones (para pruebas)") { |valor| opciones[:limite] = valor }
        opts.on("--lote N", Integer, "Registros por sentencia INSERT (default 250)") { |valor| opciones[:lote] = valor }
        opts.on("--sql RUTA", "Escribe el SQL de los INSERT con literales") { |valor| opciones[:sql] = valor }
        opts.on("--reporte RUTA", "Escribe un CSV con las incidencias") { |valor| opciones[:reporte] = valor }
        opts.on("-h", "--help", "Muestra esta ayuda") do
          puts opts
          exit(0)
        end
      end
      parser.parse(argv)
      opciones
    end

    def self.cargar_mapa
      mapa_catalogos
    end

    def self.external_ids_existentes(base)
      filas = base.consultar("SELECT DISTINCT external_id FROM #{TABLA} WHERE external_id IS NOT NULL")
      filas.map { |fila| normalizar_external_id(fila["EXTERNAL_ID"]) }.to_set
    end

    def self.distribuciones_existentes(base, nuevos)
      ids = nuevos.map { |fila| uuid(fila["CONTRACT_INVESTMENT_DISTRIBUTION_ID"]) }.compact.uniq
      existentes = Set.new
      ids.each_slice(1000) do |lote|
        placeholders = lote.each_index.map { |indice| "$#{indice + 1}" }.join(", ")
        sql = "SELECT contract_investment_distribution_id::text AS id " \
              "FROM contracts_investment_distributions " \
              "WHERE contract_investment_distribution_id IN (#{placeholders})"
        base.consultar(sql, lote).each { |fila| existentes << fila["ID"] }
      end
      existentes
    end

    def self.programas_existentes(base, nuevos)
      ids = nuevos.map { |fila| uuid(fila["PROGRAM_ID"]) }.compact.uniq
      existentes = Set.new
      ids.each_slice(1000) do |lote|
        placeholders = lote.each_index.map { |indice| "$#{indice + 1}" }.join(", ")
        sql = "SELECT program_id::text AS id FROM programs WHERE program_id IN (#{placeholders})"
        base.consultar(sql, lote).each { |fila| existentes << fila["ID"] }
      end
      existentes
    end

    # Genera [valores_por_registro, incidencias]. Cada fila de valores respeta COLUMNAS.
    def self.construir_registros(nuevos, mapa, distribuciones, programas)
      valores = []
      incidencias = []

      nuevos.each do |fila|
        external_id = normalizar_external_id(fila["EXTENAL_ID"])
        dist = uuid(fila["CONTRACT_INVESTMENT_DISTRIBUTION_ID"])
        dist = nil unless dist && distribuciones.include?(dist)
        incidencias << [external_id, "distribucion_no_existe", fila["CONTRACT_INVESTMENT_DISTRIBUTION_ID"]] if dist.nil? && !fila["CONTRACT_INVESTMENT_DISTRIBUTION_ID"].strip.empty?

        cce = resolver_catalogo(mapa["cce"], fila["EXTERNAL_CAT_CONST_CENTER_CONSUMPTION"], "cce", external_id, incidencias)
        art = resolver_catalogo(mapa["art"], fila["EXTERNAL_CAT_ACCOUNTING_RECORD_TYPES"], "art", external_id, incidencias)
        sales_type = resolver_catalogo(mapa["sales_type"], fila["EXTERNAL_CAT_SALES_TYPES"], "sales_type", external_id, incidencias)
        sd = resolver_catalogo(mapa["sd"], fila["EXTERNAL_CAT_SALES_DETAILS_TYPE"], "sd", external_id, incidencias)

        business_area = uuid(fila["BUSINESS_AREAS_ID"])

        program = uuid(fila["PROGRAM_ID"])
        if program && !programas.include?(program)
          incidencias << [external_id, "programa_no_existe", program]
        end

        valores << [
          SecureRandom.uuid,
          dist,
          cce,
          texto(fila["CCE_NUMER"]),
          decimal(fila["AMOUNT"]),
          booleano(fila["SAP_SEND"]),
          texto(fila["COMENTS"]),
          estado_para(external_id),
          art,
          sales_type,
          business_area,
          fecha(fila["CONSUMPTION_DATE"]),
          decimal(fila["COST_AMOUNT"]),
          sd,
          texto(fila["DOCUMENT_CLASS"]),
          texto(fila["OTJ_KEY"]),
          booleano(fila["IS_COMPLEMENT"]),
          program,
          texto(fila["COST_CC"]),
          texto(fila["UPLOAD_KEY"]),
          decimal(fila["UPLOAD_CONSECUTIVE"]),
          fecha(fila["ORIGINAL_DATE"]),
          decimal(fila["SUB_PRODUCTION"]),
          external_id
        ]
      end

      [valores, incidencias]
    end

    def self.construir_actualizaciones(filas, mapa)
      actualizaciones = []
      incidencias = []

      filas.each do |fila|
        external_id = normalizar_external_id(fila["EXTENAL_ID"])
        cce = resolver_catalogo(mapa["cce"], fila["EXTERNAL_CAT_CONST_CENTER_CONSUMPTION"], "cce", external_id, incidencias)
        art = resolver_catalogo(mapa["art"], fila["EXTERNAL_CAT_ACCOUNTING_RECORD_TYPES"], "art", external_id, incidencias)
        sales_type = resolver_catalogo(mapa["sales_type"], fila["EXTERNAL_CAT_SALES_TYPES"], "sales_type", external_id, incidencias)
        sd = resolver_catalogo(mapa["sd"], fila["EXTERNAL_CAT_SALES_DETAILS_TYPE"], "sd", external_id, incidencias)
        next if [cce, art, sales_type, sd].compact.empty?

        actualizaciones << [external_id, cce, art, sales_type, sd]
      end

      [actualizaciones, incidencias]
    end

    def self.resolver_catalogo(mapa_categoria, codigo, categoria, external_id, incidencias)
      codigo = codigo.to_s.strip
      return nil if codigo.empty? || codigo == "0"

      uuid_resuelto = mapa_categoria[codigo]
      incidencias << [external_id, "catalogo_sin_match_#{categoria}", codigo] if uuid_resuelto.nil?
      uuid_resuelto
    end

    def self.texto(valor)
      limpio = valor.to_s.strip
      limpio.empty? ? nil : limpio
    end

    def self.resumen(registros, anomalias, nuevos_todos, valores, incidencias, opciones, actualizaciones)
      corregidas = anomalias.count { |anomalia| anomalia[:corregida] }
      ignoradas = anomalias.size - corregidas
      existentes = registros.size - nuevos_todos.size
      puts "Archivo: #{RUTA_CONSUMOS}"
      puts "Registros leídos: #{registros.size} | corregidos: #{corregidas} | ignorados: #{ignoradas}"
      puts "Ya existen en DSM: #{existentes}#{opciones[:actualizar] ? " (se actualizarán sus catálogos si están en NULL)" : ' (se omiten)'}"
      puts "Nuevos por insertar: #{valores.size}#{opciones[:limite] ? " (de #{nuevos_todos.size}, limitado con --limite #{opciones[:limite]})" : ""}"
      if opciones[:actualizar]
        puts "Actualizaciones de catálogos: #{actualizaciones.size}" \
             "#{opciones[:limite] ? " (limitado con --limite #{opciones[:limite]})" : ""}"
      end

      motivos = incidencias.group_by { |(_, motivo, _)| motivo }.transform_values(&:size)
      motivos.each { |motivo, total| puts "  #{motivo}: #{total}" }

      muestreados = valores.first(2)
      return if muestreados.empty?

      puts "\nMuestra de valores a insertar:"
      muestreados.each do |fila|
        puts "  #{COLUMNAS.zip(fila).map { |columna, valor| "#{columna}=#{valor.inspect}" }.join(", ")}"
      end
    end

    def self.escribir_reporte(incidencias, ruta)
      CSV.open(ruta, "w") do |csv|
        csv << %w[external_id motivo valor]
        incidencias.each { |fila| csv << fila }
      end
      puts "\nReporte de incidencias: #{ruta} (#{incidencias.size} fila(s))"
    end

    def self.escribir_sql(valores, actualizaciones, ruta)
      File.open(ruta, "w") do |archivo|
        archivo.puts "-- Generado por insertar_consumos.rb"
        archivo.puts "-- Registros: #{valores.size}"
        valores.each do |fila|
          placeholders = COLUMNAS.each_index.map { |indice| Ithic::Sql.literal(fila[indice]) }
          archivo.puts "INSERT INTO #{Ithic::Sql.identificador(TABLA)} " \
                       "(#{COLUMNAS.map { |columna| Ithic::Sql.identificador(columna) }.join(', ')}) " \
                       "VALUES (#{placeholders.join(', ')});"
        end
        actualizaciones.each do |external_id, cce, art, sales_type, sd|
          archivo.puts "UPDATE #{Ithic::Sql.identificador(TABLA)} SET " \
                       "cat_cost_center_consumption_id = COALESCE(cat_cost_center_consumption_id, #{Ithic::Sql.literal(cce)}), " \
                       "cat_accounting_record_type_id = COALESCE(cat_accounting_record_type_id, #{Ithic::Sql.literal(art)}), " \
                       "cat_sale_type_id = COALESCE(cat_sale_type_id, #{Ithic::Sql.literal(sales_type)}), " \
                       "cat_sale_detail_type_id = COALESCE(cat_sale_detail_type_id, #{Ithic::Sql.literal(sd)}), " \
                       "updated_at = now() WHERE external_id = #{Ithic::Sql.literal(external_id)};"
        end
      end
      puts "\nSQL generado: #{ruta} (#{valores.size} INSERT, #{actualizaciones.size} UPDATE)"
    end

    def self.insertar(base, valores, tamano_lote)
      total_lotes = (valores.size.to_f / tamano_lote).ceil
      valores.each_slice(tamano_lote).with_index(1) do |lote, indice|
        base.conexion.transaction do
          base.ejecutar(sentencia_lote(lote), lote.flatten(1))
        end
        puts "  lote #{indice}/#{total_lotes} (#{lote.size} registros)" if indice == 1 || (indice % 20).zero? || indice == total_lotes
      end
    end

    def self.sentencia_lote(filas)
      columnas_sql = COLUMNAS.map { |columna| Ithic::Sql.identificador(columna) }.join(", ")
      grupos = filas.each_index.map do |indice|
        base = indice * COLUMNAS.size
        "(#{(1..COLUMNAS.size).map { |posicion| "$#{base + posicion}" }.join(', ')})"
      end
      "INSERT INTO #{Ithic::Sql.identificador(TABLA)} (#{columnas_sql}) VALUES #{grupos.join(', ')} " \
        "ON CONFLICT (#{Ithic::Sql.identificador('consumption_blocked_details_id')}) DO NOTHING"
    end

    def self.actualizar(base, actualizaciones, tamano_lote)
      total_lotes = (actualizaciones.size.to_f / tamano_lote).ceil
      actualizaciones.each_slice(tamano_lote).with_index(1) do |lote, indice|
        base.conexion.transaction do
          base.ejecutar(sentencia_actualizacion(lote), lote.flatten(1))
        end
        if indice == 1 || (indice % 20).zero? || indice == total_lotes
          puts "  actualización lote #{indice}/#{total_lotes} (#{lote.size} registros)"
        end
      end
      puts "#{actualizaciones.size} registro(s) con catálogos actualizados en #{TABLA}"
    end

    def self.sentencia_actualizacion(filas)
      grupos = filas.each_index.map do |indice|
        base = indice * 5
        "($#{base + 1}::varchar, $#{base + 2}::uuid, $#{base + 3}::uuid, " \
          "$#{base + 4}::uuid, $#{base + 5}::uuid)"
      end
      <<~SQL
        UPDATE #{Ithic::Sql.identificador(TABLA)} AS d
        SET cat_cost_center_consumption_id = COALESCE(d.cat_cost_center_consumption_id, v.cce),
            cat_accounting_record_type_id = COALESCE(d.cat_accounting_record_type_id, v.art),
            cat_sale_type_id = COALESCE(d.cat_sale_type_id, v.sales_type),
            cat_sale_detail_type_id = COALESCE(d.cat_sale_detail_type_id, v.sd),
            updated_at = now()
        FROM (VALUES #{grupos.join(', ')}) AS v(external_id, cce, art, sales_type, sd)
        WHERE d.external_id = v.external_id
          AND (d.cat_cost_center_consumption_id IS NULL
            OR d.cat_accounting_record_type_id IS NULL
            OR d.cat_sale_type_id IS NULL
            OR d.cat_sale_detail_type_id IS NULL)
      SQL
    end
  end
end

exit(MigracionConsumos::Insertador.ejecutar(ARGV))
