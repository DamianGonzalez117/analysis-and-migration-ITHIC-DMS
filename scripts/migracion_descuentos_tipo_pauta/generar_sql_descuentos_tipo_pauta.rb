#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "optparse"
require "pathname"
require "securerandom"

RAIZ_PROYECTO = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(RAIZ_PROYECTO, "lib"))
require "ithic"

module GeneracionDescuentosTipoPauta
  class ErrorReporte < StandardError; end

  ARCHIVO_POR_DEFECTO = File.join(
    RAIZ_PROYECTO, "data", "entrada", "descuentos_tipo_pauta", "Descuentos_tipo_pauta_26.txt"
  )
  DIR_MIGRACIONES = "/home/damiangonzalez/DataGripProjects/copan/Migraciones/Descuentos Tipo Pauta"
  CAMPOS = %w[TF SR PI].freeze

  CONSULTA = <<~SQL
    SELECT
        con.contract_id,
        con.external_id AS external_contract,
        cdi.contract_discount_id AS discount_id,
        cdi.external_id AS external_discount,
        cdi.name AS name_discount,
        MAX(CASE WHEN gty.short_name LIKE '%TF%' THEN 1 ELSE 0 END) AS TF,
        MAX(CASE WHEN gty.short_name LIKE '%SR%' THEN 1 ELSE 0 END) AS SR,
        MAX(CASE WHEN gty.short_name LIKE '%PI%' THEN 1 ELSE 0 END) AS PI
    FROM core.contracts con
    INNER JOIN core.contract_discounts cdi ON cdi.contract_id = con.contract_id
    LEFT JOIN core.contract_discount_guideline_types cdgt ON cdgt.contract_discount_id = cdi.contract_discount_id
    LEFT JOIN core.guideline_types gty ON gty.guideline_type_id = cdgt.guideline_type_id
    WHERE con.year IN ($1)
    GROUP BY con.contract_id, con.external_id, cdi.contract_discount_id, cdi.external_id, cdi.name
  SQL

  module_function

  def ejecutar(argv)
    opciones = parsear(argv)
    cargar_env!

    archivo = Pathname.new(opciones[:archivo]).expand_path
    anio = inferir_anio(archivo)
    ahora = Time.now
    fecha_carpeta = ahora.strftime("%d-%m-%y")
    creado_por = "migracion-#{ahora.strftime('%d%m%y')}@muhami.com"
    ruta_sql = opciones[:sql] ||
               File.join(DIR_MIGRACIONES, fecha_carpeta, "Descuentos Tipo Pauta #{fecha_carpeta}.sql")
    base = nil

    begin
      base = Ithic::BaseDatos.desde(Ithic::Configuracion.new)
      describir_conexion
      puts "Archivo ITHIC: #{archivo} (año #{anio})"

      tipos = cargar_tipos(base)
      estado = cargar_estado_activo(base, opciones[:object_status])
      fuente = Ithic::LectorTxt.leer(archivo)
      plan = comparar(fuente.filas, anio, base)

      escribir_sql(ruta_sql, plan, tipos, estado, creado_por, archivo, anio, ahora)
      imprimir_resumen(plan, tipos, estado, ruta_sql, creado_por, anio)
      0
    rescue Ithic::ErrorIthic, PG::Error, OptionParser::ParseError, ErrorReporte => e
      warn "\nERROR: #{e.message}"
      1
    ensure
      base&.cerrar
    end
  end

  def parsear(argv)
    opciones = { archivo: nil, sql: nil, object_status: nil }
    parser = OptionParser.new do |opts|
      opts.banner = "Uso: bundle exec ruby scripts/migracion_descuentos_tipo_pauta/generar_sql_descuentos_tipo_pauta.rb [ARCHIVO]"
      opts.on("-a", "--archivo RUTA", "Archivo ITHIC separado por |") { |ruta| opciones[:archivo] = ruta }
      opts.on("--sql RUTA", "Ruta del SQL generado") { |ruta| opciones[:sql] = ruta }
      opts.on("--object-status UUID", "object_status_id a usar en los INSERT") do |uuid|
        opciones[:object_status] = uuid
      end
      opts.on("-h", "--help", "Muestra esta ayuda") do
        puts opts
        exit(0)
      end
    end
    parser.parse!(argv)

    opciones[:archivo] ||= argv.shift || ARCHIVO_POR_DEFECTO
    raise ErrorReporte, "Argumentos no reconocidos: #{argv.join(' ')}" unless argv.empty?

    opciones
  end

  def cargar_env!
    ruta = File.join(RAIZ_PROYECTO, ".env")
    return unless File.file?(ruta)

    File.readlines(ruta).each do |linea|
      linea = linea.strip
      next if linea.empty? || linea.start_with?("#") || !linea.include?("=")

      clave, _, valor = linea.partition("=")
      ENV[clave.strip] = valor.strip.gsub(/\A["']|["']\z/, "")
    end
  end

  def describir_conexion
    puts "Host: #{ENV['CONNECTION_STRING']} | base: #{ENV['DATABASE']} | " \
         "usuario: #{ENV['USER']} | esquema: #{ENV['SCHEMA']}"
  end

  def inferir_anio(archivo)
    nombre = archivo.basename.to_s
    coincidencia = nombre.match(/_(\d{2,4})\.txt\z/i)
    unless coincidencia
      raise ErrorReporte,
            "No se pudo inferir el año desde #{nombre}; usa el sufijo _26.txt, _2026.txt, etc."
    end

    anio = coincidencia[1].to_i
    anio += 2000 if anio < 100
    unless (2000..2099).cover?(anio)
      raise ErrorReporte, "El año inferido no es válido: #{anio}"
    end

    anio
  end

  def cargar_tipos(base)
    filas = base.consultar(<<~SQL)
      SELECT gt.guideline_type_id, gt.short_name
      FROM core.guideline_types gt
      INNER JOIN core.object_status os ON os.object_status_id = gt.object_status_id
      INNER JOIN core.cat_status cs ON cs.cat_status_id = os.cat_status_id
      WHERE gt.short_name IN ('TF', 'SR', 'PI')
        AND cs.short_name = 'ACTIVO'
    SQL

    por_nombre = filas.group_by { |fila| fila["SHORT_NAME"].to_s.strip.upcase }
    CAMPOS.to_h do |campo|
      candidatos = por_nombre[campo] || []
      if candidatos.size != 1
        raise ErrorReporte,
              "Se esperaba un guideline_type ACTIVO para #{campo}; encontrados: #{candidatos.size}"
      end

      [campo, candidatos.first["GUIDELINE_TYPE_ID"]]
    end
  end

  def cargar_estado_activo(base, override)
    if override
      fila = base.consultar(<<~SQL, [override]).first
        SELECT os.object_status_id, cs.short_name
        FROM core.object_status os
        INNER JOIN core.cat_status cs ON cs.cat_status_id = os.cat_status_id
        WHERE os.object_status_id = $1
      SQL
      if fila.nil?
        raise ErrorReporte, "No existe el object_status_id #{override}"
      end
      unless fila["SHORT_NAME"].to_s.casecmp("ACTIVO").zero?
        raise ErrorReporte, "El object_status_id #{override} no está ACTIVO"
      end

      return override
    end

    fila = base.consultar(<<~SQL).first
      SELECT cdgt.object_status_id, COUNT(*) AS cantidad
      FROM core.contract_discount_guideline_types cdgt
      INNER JOIN core.object_status os ON os.object_status_id = cdgt.object_status_id
      INNER JOIN core.cat_status cs ON cs.cat_status_id = os.cat_status_id
      WHERE cs.short_name = 'ACTIVO'
      GROUP BY cdgt.object_status_id
      ORDER BY cantidad DESC
      LIMIT 1
    SQL
    if fila.nil?
      raise ErrorReporte,
            "No se pudo determinar el object_status_id ACTIVO de contract_discount_guideline_types; " \
            "usa --object-status UUID"
    end

    fila["OBJECT_STATUS_ID"]
  end

  def comparar(filas_ithic, anio, base)
    filas_dsm = base.consultar(CONSULTA, [anio.to_s])
    dsm_por_clave = filas_dsm.to_h { |fila| [clave(fila), fila] }
    duplicados = filas_ithic.group_by { |fila| clave(fila) }.select { |_, filas| filas.size > 1 }
    unless duplicados.empty?
      raise ErrorReporte,
            "El archivo ITHIC tiene claves duplicadas: #{duplicados.keys.first(5).map { |c| c.join('/') }.join(', ')}"
    end

    inserts = []
    advertencias = []
    filas_ithic.each do |fila_ithic|
      clave_registro = clave(fila_ithic)
      fila_dsm = dsm_por_clave[clave_registro]
      datos = {
        contrato_id: id_canonico(fila_ithic["CONTRACT_ID"]),
        external_contract: valor_campo(fila_ithic, "EXTERNAL_CONTRACT"),
        descuento_id: id_canonico(fila_ithic["DISCOUNT_ID"]),
        external_discount: valor_campo(fila_ithic, "EXTERNAL_DISCOUNT"),
        nombre: nombre_legible(fila_ithic["NAME_DISCOUNT"])
      }

      if fila_dsm.nil?
        campos = CAMPOS.select { |campo| valor_campo(fila_ithic, campo) == "1" }
        advertencias << datos.merge(
          tipo: :descuento_ausente,
          campos: campos,
          detalle: "El descuento no existe en DSM; no se puede insertar el tipo de pauta"
        )
        next
      end

      CAMPOS.each do |campo|
        valor_ithic = valor_campo(fila_ithic, campo)
        valor_dsm = valor_campo(fila_dsm, campo)
        unless %w[0 1].include?(valor_ithic) && %w[0 1].include?(valor_dsm)
          raise ErrorReporte,
                "Valor inesperado en #{campo} para #{datos[:external_contract]}/#{datos[:external_discount]}: " \
                "ITHIC=#{valor_ithic.inspect}, DSM=#{valor_dsm.inspect}"
        end

        if valor_ithic == "1" && valor_dsm == "0"
          inserts << datos.merge(campo: campo)
        elsif valor_ithic == "0" && valor_dsm == "1"
          advertencias << datos.merge(
            tipo: :sobrante,
            campos: [campo],
            detalle: "DSM tiene #{campo} y el archivo ITHIC no; revisar/eliminar manualmente"
          )
        end
      end
    end

    orden_campos = CAMPOS.each_with_index.to_h
    inserts.sort_by! do |fila|
      [fila[:external_contract].to_i, fila[:external_discount].to_i, orden_campos.fetch(fila[:campo])]
    end
    advertencias.sort_by! do |fila|
      [fila[:external_contract].to_i, fila[:external_discount].to_i, fila[:tipo].to_s]
    end

    {
      total_ithic: filas_ithic.size,
      total_dsm: filas_dsm.size,
      inserts: inserts,
      advertencias: advertencias
    }
  end

  def clave(fila)
    [normalizar_id(fila["CONTRACT_ID"]), normalizar_id(fila["DISCOUNT_ID"])]
  end

  def normalizar_id(valor)
    valor.to_s.strip.delete("-").upcase
  end

  def id_canonico(valor)
    Ithic::Normalizador.uuid_postgres(valor)
  end

  def valor_campo(fila, campo)
    fila.nil? ? "" : fila[campo].to_s.strip
  end

  def nombre_legible(valor)
    valor.to_s.strip.gsub("\u0096", "–").gsub(/[\u0080-\u009F]/, "")
  end

  def escribir_sql(ruta, plan, tipos, estado, creado_por, archivo, anio, ahora)
    lineas = []
    lineas << "-- Descuentos por tipo de pauta #{anio}"
    lineas << "-- Generado: #{ahora.strftime('%Y-%m-%d %H:%M:%S')}"
    lineas << "-- Archivo ITHIC: #{archivo}"
    lineas << "-- created_by: #{creado_por}"
    lineas << "-- object_status_id: #{estado}"
    lineas << "-- INSERT: #{plan[:inserts].size}"
    unless plan[:advertencias].empty?
      lineas << "-- ADVERTENCIAS: #{plan[:advertencias].size} (revisar antes de ejecutar)"
      plan[:advertencias].each do |advertencia|
        campos = advertencia[:campos].empty? ? "sin tipos" : advertencia[:campos].join("/")
        lineas << "-- - #{advertencia[:external_contract]}/#{advertencia[:external_discount]} " \
                  "#{advertencia[:nombre]} (#{campos}): #{advertencia[:detalle]}"
      end
    end
    lineas << "BEGIN;"
    lineas << ""

    plan[:inserts].each do |insert|
      lineas << "-- Contrato #{insert[:external_contract]} (#{insert[:contrato_id]}) | " \
                "Descuento #{insert[:external_discount]} (#{insert[:descuento_id]}) | " \
                "#{insert[:nombre]} | #{insert[:campo]}"
      lineas << "INSERT INTO core.contract_discount_guideline_types (" \
                "contract_discount_guideline_type_id, contract_discount_id, guideline_type_id, " \
                "object_status_id, created_by, created_at)"
      lineas << "VALUES ('#{SecureRandom.uuid}', '#{insert[:descuento_id]}', '#{tipos.fetch(insert[:campo])}', " \
                "'#{estado}', '#{creado_por}', now())"
      lineas << "ON CONFLICT (contract_discount_id, guideline_type_id) DO NOTHING;"
      lineas << ""
    end

    lineas << "COMMIT;"
    FileUtils.mkdir_p(File.dirname(ruta))
    File.write(ruta, lineas.join("\n") + "\n")
  end

  def imprimir_resumen(plan, tipos, estado, ruta_sql, creado_por, anio)
    puts "Registros ITHIC: #{plan[:total_ithic]} | Registros DSM: #{plan[:total_dsm]}"
    puts "Tipos de pauta: " + CAMPOS.map { |campo| "#{campo}=#{tipos[campo]}" }.join(" | ")
    puts "object_status_id ACTIVO: #{estado}"
    puts "created_by: #{creado_por}"
    conteo = plan[:inserts].group_by { |insert| insert[:campo] }.transform_values(&:size)
    detalle = CAMPOS.map { |campo| "#{campo} #{conteo.fetch(campo, 0)}" }.join(", ")
    puts "INSERT generados: #{plan[:inserts].size}#{plan[:inserts].empty? ? '' : " (#{detalle})"}"
    puts "Advertencias: #{plan[:advertencias].size}"
    plan[:advertencias].each do |advertencia|
      campos = advertencia[:campos].empty? ? "sin tipos" : advertencia[:campos].join("/")
      puts "  - #{advertencia[:external_contract]}/#{advertencia[:external_discount]} " \
           "#{advertencia[:nombre]} (#{campos}): #{advertencia[:detalle]}"
    end
    puts "SQL: #{ruta_sql}"
    puts "Año: #{anio}"
  end
end

exit(GeneracionDescuentosTipoPauta.ejecutar(ARGV))
