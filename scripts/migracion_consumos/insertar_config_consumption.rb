#!/usr/bin/env ruby
# frozen_string_literal: true

# Migra data_config_consumption.txt (configuración de consumos de ITHIC) a DSM.
#
# Reglas:
# - La existencia se evalúa por clave de negocio (área, tipo de venta, tipo de
#   contrato de inversión, registro contable, centro de costo y detalle de venta),
#   no por UUID de catálogo: la migración previa pudo haber elegido otra fila
#   duplicada del mismo catálogo.
# - Si la clave ya existe, el registro se omite (salvo --actualizar, que corrige
#   account_cost y send_sap_cost de la fila existente).
# - Registros nuevos: UUID generado y object_status ACTIVO (consistente con los
#   catálogos y las filas ya existentes de esta tabla).
# - account_cost vacío => 0 (columna NOT NULL); send_sap_cost: "1" => true,
#   vacío/"0" => false.
#
# Uso:
#   bundle exec ruby scripts/migracion_consumos/insertar_config_consumption.rb
#   bundle exec ruby scripts/migracion_consumos/insertar_config_consumption.rb --actualizar --ejecutar
#   bundle exec ruby scripts/migracion_consumos/insertar_config_consumption.rb --limite 5 --ejecutar

require "optparse"
require_relative "comun"

module MigracionConsumos
  module InsertadorConfig
    extend MigracionConsumos

    TABLA = "data_config_consumption"
    ARCHIVO = "data_config_consumption.txt"
    OBJECT_STATUS_CONFIG = "01905186-4ff0-7041-93a3-404eff394ff9" # ACTIVO
    COLUMNAS = %w[
      data_config_consumption_id
      business_areas_id
      cat_sale_type_id
      cat_investment_contract_type_id
      cat_accounting_record_type_id
      cat_cost_center_consumption_id
      cat_sale_detail_type_id
      object_status_id
      account_cost
      send_sap_cost
      created_by
    ].freeze

    def self.ejecutar(argv)
      opciones = parsear_opciones(argv)
      mapa = mapa_catalogos
      registros, incidencias = leer_registros(mapa)

      base = conexion
      begin
        existentes = configuraciones_existentes(base)
        nuevos = registros.reject { |registro| existentes.key?(registro[:clave]) }
        repetidos = registros.select { |registro| existentes.key?(registro[:clave]) }
        actualizaciones = repetidos.filter_map do |registro|
          actual = existentes[registro[:clave]]
          next if actual[:account_cost] == registro[:account_cost] && actual[:send_sap_cost] == registro[:send_sap_cost]

          { id: actual[:id], account_cost: registro[:account_cost], send_sap_cost: registro[:send_sap_cost] }
        end

        nuevos = nuevos.first(opciones[:limite]) if opciones[:limite]
        actualizaciones = actualizaciones.first(opciones[:limite]) if opciones[:limite]

        resumen(registros, incidencias, nuevos, repetidos, actualizaciones, opciones)
        escribir_sql(nuevos, actualizaciones, opciones[:sql]) if opciones[:sql]

        if opciones[:ejecutar]
          insertar(base, nuevos, opciones[:lote]) unless nuevos.empty?
          actualizar(base, actualizaciones) if opciones[:actualizar] && !actualizaciones.empty?
          puts "\n#{nuevos.size} registro(s) insertado(s), #{opciones[:actualizar] ? actualizaciones.size : 0} actualizado(s)"
        else
          puts "\nSimulación: no se ejecutó nada. Usa --ejecutar para aplicar."
        end
      ensure
        base.cerrar
      end
      0
    end

    def self.parsear_opciones(argv)
      opciones = { ejecutar: false, actualizar: false, limite: nil, lote: 250, sql: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Uso: bundle exec ruby scripts/migracion_consumos/insertar_config_consumption.rb [opciones]"
        opts.on("--ejecutar", "Aplica los cambios (por defecto solo simula)") { opciones[:ejecutar] = true }
        opts.on("--actualizar", "Corrige account_cost y send_sap_cost en filas existentes") { opciones[:actualizar] = true }
        opts.on("--limite N", Integer, "Procesa solo N filas de cada grupo (pruebas)") { |valor| opciones[:limite] = valor }
        opts.on("--lote N", Integer, "Filas por sentencia INSERT (default 250)") { |valor| opciones[:lote] = valor }
        opts.on("--sql RUTA", "Escribe el SQL generado con literales") { |valor| opciones[:sql] = valor }
        opts.on("-h", "--help", "Muestra esta ayuda") do
          puts opts
          exit(0)
        end
      end
      parser.parse(argv)
      opciones
    end

    # Devuelve [registros, incidencias]. Cada registro: {clave:, valores: [uuid...], account_cost:, send_sap_cost:, external:}
    def self.leer_registros(mapa)
      _, filas = leer_catalogo(ARCHIVO)
      nombre_sd = nombres_sd

      incidencias = []
      registros = []
      filas.each do |fila|
        ba = uuid(fila["BUSINESS_AREAS_ID"])
        ict = uuid(fila["CAT_INVESTMENT_CONTRACT_TYPE_ID"])
        st_code = fila["EXTERNAL_CAT_SALES_TYPES"].to_s.strip
        art_code = fila["EXTERNAL_CAT_ACCOUNTING_RECORD_TYPE_ID"].to_s.strip
        cce_code = fila["EXTERNAL_CAT_COST_CENTER_CONSUMPTION"].to_s.strip
        sd_code = fila["EXTERNAL_CAT_SALES_DETAILS_TYPES"].to_s.strip

        st = mapa["sales_type"][st_code]
        art = mapa["art"][art_code]
        cce = mapa["cce"][cce_code]
        sd = mapa["sd"][sd_code]
        sd_nombre = nombre_sd[sd_code]

        faltantes = { "sales_type" => [st_code, st], "art" => [art_code, art],
                      "cce" => [cce_code, cce], "sd" => [sd_code, sd] }
                    .select { |_, (codigo, resuelto)| resuelto.nil? && !codigo.empty? && codigo != "0" }
        faltantes["ict"] = [fila["CAT_INVESTMENT_CONTRACT_TYPE_ID"], ict] if ict.nil?
        unless faltantes.empty?
          incidencias << [ba, faltantes.keys.join(","), fila.values.join("|")]
          next
        end

        clave = [ba, st_code, ict, art_code, cce_code, sd_nombre]
        valores = [
          SecureRandom.uuid,
          ba,
          st,
          ict,
          art,
          cce,
          sd,
          OBJECT_STATUS_CONFIG,
          decimal(fila["ACCOUNT_COST"]) || BigDecimal("0"),
          booleano(fila["SEND_SAP_COST"]),
          CREADO_POR
        ]
        registros << { clave: clave, valores: valores,
                       account_cost: valores[8], send_sap_cost: valores[9] }
      end
      [registros, incidencias]
    end

    # código externo => nombre del catálogo de detalles de venta (archivo)
    def self.nombres_sd
      _, filas = leer_catalogo("cat_sales_details_types.txt")
      filas.each_with_object({}) do |fila, mapa|
        mapa[fila["EXTERNAL_ID"].to_s.strip] = fila["NAME"].to_s.strip.downcase
      end
    end

    def self.configuraciones_existentes(base)
      inv_st = mapa_inverso(base, "cat_sales_types", "cat_sale_type_id")
      inv_art = mapa_inverso(base, "cat_accounting_record_types", "cat_accounting_record_type_id")
      inv_cce = mapa_inverso(base, "cat_cost_center_consumption", "cat_cost_center_consumption_id")
      inv_sd = mapa_inverso_sd(base)

      filas = base.consultar(<<~SQL)
        SELECT data_config_consumption_id::text AS id, business_areas_id::text AS ba,
               cat_sale_type_id::text AS st, cat_investment_contract_type_id::text AS ict,
               cat_accounting_record_type_id::text AS art,
               cat_cost_center_consumption_id::text AS cce,
               cat_sale_detail_type_id::text AS sd,
               account_cost, send_sap_cost
        FROM #{TABLA}
      SQL

      filas.each_with_object({}) do |fila, existentes|
        clave = [
          fila["BA"],
          fila["ST"] && inv_st[fila["ST"]],
          fila["ICT"],
          fila["ART"] && inv_art[fila["ART"]],
          fila["CCE"] && inv_cce[fila["CCE"]],
          fila["SD"] && inv_sd[fila["SD"]]
        ]
        existentes[clave] = {
          id: fila["ID"],
          account_cost: decimal(fila["ACCOUNT_COST"]) || BigDecimal("0"),
          send_sap_cost: fila["SEND_SAP_COST"] == "t"
        }
      end
    end

    def self.mapa_inverso(base, tabla, id_col)
      base.consultar("SELECT #{id_col}::text AS uuid, external_id::text AS ext FROM #{tabla} WHERE external_id IS NOT NULL")
          .each_with_object({}) { |fila, mapa| mapa[fila["UUID"]] = fila["EXT"].to_s.strip }
    end

    def self.mapa_inverso_sd(base)
      base.consultar("SELECT cat_sale_detail_type_id::text AS uuid, name FROM cat_sales_details_types")
          .each_with_object({}) { |fila, mapa| mapa[fila["UUID"]] = fila["NAME"].to_s.strip.downcase }
    end

    def self.resumen(registros, incidencias, nuevos, repetidos, actualizaciones, opciones)
      puts "Archivo: #{File.join(DIR_CONSUMOS, ARCHIVO)}"
      puts "Registros leídos: #{registros.size} | incidencias (no insertables): #{incidencias.size}"
      puts "Ya existen en DSM (se omiten): #{repetidos.size}"
      puts "Nuevos por insertar: #{nuevos.size}#{opciones[:limite] ? " (limitado con --limite #{opciones[:limite]})" : ""}"
      puts "Existentes con valores distintos: #{actualizaciones.size}" \
           "#{opciones[:actualizar] ? ' (se corregirán)' : ' (usa --actualizar para corregirlos)'}"
      incidencias.first(5).each { |fila| puts "  incidencia: ba=#{fila[0]} campos=#{fila[1]}" }

      nuevos.first(2).each do |registro|
        campos = COLUMNAS.zip(registro[:valores]).map { |columna, valor| "#{columna}=#{valor.inspect}" }
        puts "  nuevo: #{campos.join(', ')}"
      end
      actualizaciones.first(2).each do |actualizacion|
        puts "  actualizar: id=#{actualizacion[:id]} account_cost=#{actualizacion[:account_cost]} " \
             "send_sap_cost=#{actualizacion[:send_sap_cost]}"
      end
    end

    def self.escribir_sql(nuevos, actualizaciones, ruta)
      File.open(ruta, "w") do |archivo|
        archivo.puts "-- Generado por insertar_config_consumption.rb"
        nuevos.each do |registro|
          literales = registro[:valores].map { |valor| Ithic::Sql.literal(valor) }
          archivo.puts "INSERT INTO #{Ithic::Sql.identificador(TABLA)} " \
                       "(#{COLUMNAS.map { |columna| Ithic::Sql.identificador(columna) }.join(', ')}) " \
                       "VALUES (#{literales.join(', ')});"
        end
        actualizaciones.each do |actualizacion|
          archivo.puts "UPDATE #{Ithic::Sql.identificador(TABLA)} SET " \
                       "account_cost = #{Ithic::Sql.literal(actualizacion[:account_cost])}, " \
                       "send_sap_cost = #{Ithic::Sql.literal(actualizacion[:send_sap_cost])}, updated_at = now() " \
                       "WHERE data_config_consumption_id = #{Ithic::Sql.literal(actualizacion[:id])};"
        end
      end
      puts "\nSQL generado: #{ruta} (#{nuevos.size} INSERT, #{actualizaciones.size} UPDATE)"
    end

    def self.insertar(base, nuevos, tamano_lote)
      nuevos.each_slice(tamano_lote) do |lote|
        base.conexion.transaction do
          base.ejecutar(sentencia_insert(lote), lote.flat_map { |registro| registro[:valores] })
        end
      end
      puts "\n#{nuevos.size} registro(s) insertado(s) en #{TABLA}"
    end

    def self.sentencia_insert(lote)
      columnas_sql = COLUMNAS.map { |columna| Ithic::Sql.identificador(columna) }.join(", ")
      grupos = lote.each_index.map do |indice|
        base = indice * COLUMNAS.size
        "(#{(1..COLUMNAS.size).map { |posicion| "$#{base + posicion}" }.join(', ')})"
      end
      "INSERT INTO #{Ithic::Sql.identificador(TABLA)} (#{columnas_sql}) VALUES #{grupos.join(', ')}"
    end

    def self.actualizar(base, actualizaciones)
      actualizaciones.each_slice(200) do |lote|
        base.conexion.transaction do
          lote.each do |actualizacion|
            base.ejecutar(
              "UPDATE #{TABLA} SET account_cost = $1, send_sap_cost = $2, updated_at = now() " \
              "WHERE data_config_consumption_id = $3",
              [actualizacion[:account_cost], actualizacion[:send_sap_cost], actualizacion[:id]]
            )
          end
        end
      end
      puts "#{actualizaciones.size} registro(s) actualizado(s) en #{TABLA}"
    end
  end
end

exit(MigracionConsumos::InsertadorConfig.ejecutar(ARGV))
