# frozen_string_literal: true

require "csv"
require "fileutils"
require "optparse"
require "securerandom"
require "set"

RAIZ_PROYECTO = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(RAIZ_PROYECTO, "lib"))
require "ithic"

module MigracionMarcas
  class ErrorMigracion < StandardError; end

  DIR_ENTRADA = File.join(RAIZ_PROYECTO, "data", "entrada", "marcas")
  RUTA_MARCAS = File.join(DIR_ENTRADA, "Marcas.txt")
  RUTA_CUSTOMER_BRANDS = File.join(DIR_ENTRADA, "customer_brands.txt")
  RUTA_SUB_BRANDS = File.join(DIR_ENTRADA, "sub_brands.txt")
  DIR_REPORTES = File.join(RAIZ_PROYECTO, "data", "reportes", "marcas")
  DIR_MIGRACIONES = "/home/damiangonzalez/DataGripProjects/copan/Migraciones/Marcas y SubMarcas Nacional"

  SUBSIDIARIA_NACIONAL = "019055d0-7a3c-7972-87f3-b52706b4fc67"
  CLIENTE_POSADAS = "01904ccf-6572-7750-80c8-5c55eb10d8bd"
  ESTATUS_ACTIVO = "01905186-4ff0-7041-93a3-404eff394ff9"
  ESTATUS_SHARED = "01905186-4fed-7080-aeee-9c71a939f69a"
  MARCA_SIN_MARCA = "019cb537-c9e0-7220-966b-0b705c2c1db4"
  MARCA_ALTERNA = "019cacbc-ed45-7cce-9ce4-d6ceca682c4b"
  CREADO_POR = "migracion@muhami.mx"

  CB_68159 = "01a1476a-64a9-720e-86d2-b078ca84e29a"
  CB_67226 = "01a1476a-8d38-77ad-bd05-eb558672131c"
  CB_63005 = "01a1476a-e46d-7118-b32e-c27f121336f4"
  CB_62890 = "01a1476b-0482-7129-ad4c-35a646c98d76"
  CB_62097 = "01a1476b-3766-703e-bbff-01314a76b555"
  CB_62084 = "01a1476b-5f0f-757f-9bf6-37da5f6208d8"

  SB_68159 = "019e9059-6e39-741c-9387-4d7a4781780b"
  SB_67226 = "3fbcd0b3-7e3b-430a-e063-951b400aa6a8"
  SB_63005 = "1f362dc9-810f-7b09-e063-951b400aef46"
  SB_62890 = "1f362dc9-7442-7b09-e063-951b400aef46"
  SB_62097 = "1f362dc9-7d13-7b09-e063-951b400aef46"
  SB_62084 = "1f362dc9-6a80-7b09-e063-951b400aef46"

  SUGERENCIAS = {
    SB_68159 => "UPDATE external_id a 68159 y customer_brand_id a #{CB_68159}",
    SB_67226 => "UPDATE customer_brand_id a #{CB_67226}",
    SB_63005 => "UPDATE customer_brand_id a #{CB_63005}",
    SB_62890 => "UPDATE customer_brand_id a #{CB_62890}",
    SB_62097 => "UPDATE customer_brand_id a #{CB_62097}",
    SB_62084 => "UPDATE customer_brand_id a #{CB_62084}"
  }.freeze

  CONSULTA = <<~SQL
    select
           upper(replace(cast(sb.sub_brand_id as varchar), '-', '')) sub_brand
           ,sb.external_id, sb.bra_id_external , sb.name sub_name, sb.short_name sb_short_name, sub.subsidiary_number, sub.name subsidiary_name
    from core.sub_brands sb
    inner join core.customers_brands cb on sb.customer_brand_id = cb.customer_brand_id
    inner join core.shared_customers sc  on cb.customer_id = sc.customer_id
    inner join core.subsidiaries sub on sc.subsidiary_id = sub.subsidiary_id
    inner join core.relation_states_object_status re on sb.object_status_id = re.object_status_id
    where 1 = 1
    and subsidiary_number =0
    order by  cast(sb.external_id as integer) asc  , cast(sb.bra_id_external as integer) asc
  SQL

  module_function

  def fecha_migracion
    Time.now.strftime("%d-%m-%y")
  end

  def usuario_migracion
    "migracion-#{Time.now.strftime('%d%m%y')}@muhami.mx"
  end

  def ruta_sql_por_defecto(nombre = "Marcas y SubMarcas")
    File.join(DIR_MIGRACIONES, fecha_migracion, "#{nombre} #{fecha_migracion}.sql")
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

  def conexion
    cargar_env!
    Ithic::BaseDatos.desde(Ithic::Configuracion.new)
  end

  def leer_filas(ruta)
    raise ErrorMigracion, "No existe el archivo #{ruta}" unless File.file?(ruta)

    Ithic::LectorTxt.leer(ruta).filas
  end

  def marcas
    leer_filas(RUTA_MARCAS)
  end

  def pares_fuente
    customer_brands = leer_filas(RUTA_CUSTOMER_BRANDS)
    sub_brands = leer_filas(RUTA_SUB_BRANDS)
    if customer_brands.size != sub_brands.size
      raise ErrorMigracion, "customer_brands.txt y sub_brands.txt no tienen la misma cantidad de filas"
    end

    sub_brands.each_with_index.map do |sub_brand, indice|
      { indice: indice, sub: sub_brand, customer_brand: customer_brands[indice] }
    end
  end

  def dsm(base)
    base.consultar(CONSULTA)
  end

  def comparar(registros_marcas, registros_dsm)
    ext_marcas = registros_marcas.map { |fila| fila["EXTERNAL_ID"] }
    ext_dsm = registros_dsm.map { |fila| fila["EXTERNAL_ID"] }
    por_dsm = registros_dsm.group_by { |fila| fila["EXTERNAL_ID"] }
    faltan = ext_marcas - ext_dsm
    sobran = ext_dsm - ext_marcas
    diferencias = registros_marcas.filter_map do |fila|
      dsm_fila = por_dsm[fila["EXTERNAL_ID"]]&.first
      next unless dsm_fila
      next if dsm_fila["BRA_ID_EXTERNAL"].to_s == fila["BRA_ID_EXTERNAL"].to_s &&
              dsm_fila["SUB_NAME"].to_s == fila["SB_NAME"].to_s &&
              dsm_fila["SB_SHORT_NAME"].to_s == fila["SB_SHORT_NAME"].to_s

      {
        external_id: fila["EXTERNAL_ID"],
        bra_id_external: fila["BRA_ID_EXTERNAL"],
        nombre_ithic: fila["SB_NAME"],
        nombre_dsm: dsm_fila["SUB_NAME"],
        short_ithic: fila["SB_SHORT_NAME"],
        short_dsm: dsm_fila["SB_SHORT_NAME"]
      }
    end

    {
      total_marcas: registros_marcas.size,
      total_dsm: registros_dsm.size,
      unicos_marcas: ext_marcas.uniq.size,
      unicos_dsm: ext_dsm.uniq.size,
      faltan: faltan.sort_by(&:to_i),
      sobran: sobran.sort_by(&:to_i),
      duplicados_dsm: ext_dsm.tally.select { |_clave, cantidad| cantidad > 1 },
      diferencias: diferencias
    }
  end

  def uuid(valor)
    limpio = valor.to_s.strip.delete("-").downcase
    return nil if limpio.empty?

    [limpio[0, 8], limpio[8, 4], limpio[12, 4], limpio[16, 4], limpio[20, 12]].join("-")
  end

  def literal(valor)
    case valor
    when nil then "NULL"
    when true then "TRUE"
    when false then "FALSE"
    when Numeric then valor.to_s
    when Time then "'#{valor.utc.strftime('%Y-%m-%d %H:%M:%S.%6N+00')}'"
    else "'#{valor.to_s.gsub("'", "''")}'"
    end
  end

  def sub_brand_existente(base, sub_brand_id)
    base.consultar(
      "select sub_brand_id, external_id, customer_brand_id from core.sub_brands where sub_brand_id = $1",
      [sub_brand_id]
    ).first
  end

  def customer_brand_existente(base, customer_brand_id)
    base.consultar(
      "select customer_brand_id from core.customers_brands where customer_brand_id = $1",
      [customer_brand_id]
    ).first
  end

  def marca_insert(base)
    [MARCA_SIN_MARCA, MARCA_ALTERNA].each do |marca|
      fila = base.consultar("select brand_id from core.brands where brand_id = $1", [marca]).first
      return marca if fila
    end
    nil
  end

  def shared_existente(base, customer_id, subsidiary_id)
    base.consultar(
      "select * from core.shared_customers where customer_id = $1 and subsidiary_id = $2 limit 1",
      [customer_id, subsidiary_id]
    ).first
  end

  def shared_nacional(base, customer_id)
    shared_existente(base, customer_id, SUBSIDIARIA_NACIONAL)
  end

  def sentencia_shared(base, customer_id, subsidiary_id)
    return nil if shared_existente(base, customer_id, subsidiary_id)

    existente = base.consultar(
      "select * from core.shared_customers where customer_id = $1 order by created_at asc limit 1",
      [customer_id]
    ).first

    columnas = %w[
      shared_customer_id customer_id subsidiary_id reference_key object_status_id
      created_by updated_by created_at updated_at cat_customer_type_id corporative
      tax_id external_id is_cession_only
    ]
    valores = [
      SecureRandom.uuid,
      customer_id,
      subsidiary_id,
      nil,
      existente&.fetch("OBJECT_STATUS_ID", nil) || ESTATUS_SHARED,
      CREADO_POR,
      usuario_migracion,
      Time.now,
      Time.now,
      existente&.fetch("CAT_CUSTOMER_TYPE_ID", nil),
      existente&.fetch("CORPORATIVE", nil),
      nil,
      nil,
      false
    ]

    "INSERT INTO core.shared_customers (#{columnas.join(', ')}) " \
      "VALUES (#{valores.map { |valor| literal(valor) }.join(', ')});"
  end

  def sentencia_shared_nacional(base, customer_id)
    sentencia_shared(base, customer_id, SUBSIDIARIA_NACIONAL)
  end

  def pares_faltantes(faltan)
    externos = faltan.to_set
    pares_fuente.select { |par| externos.include?(par[:sub]["EXTERNAL_ID"]) }
  end

  def seleccionar_para_insert(base, faltan)
    pares = pares_faltantes(faltan)
    existentes = pares.filter_map do |par|
      fila = sub_brand_existente(base, uuid(par[:sub]["SUB_BRAND_ID"]))
      [par[:sub]["EXTERNAL_ID"], fila] if fila
    end

    [pares, existentes]
  end

  def insert_customer_brand(customer_brand, customer_brand_id, marca_id)
    columnas = %w[
      customer_brand_id brand_id customer_id subsidiary_id object_status_id
      created_by updated_by created_at business_subsidiary_hierarchy_structure_id external_id description
    ]
    valores = [
      customer_brand_id,
      marca_id,
      uuid(customer_brand["CUSTOMER_ID"]),
      uuid(customer_brand["SUBSIDIARY_ID"]),
      uuid(customer_brand["OBJECT_STATUS_ID"]),
      customer_brand["CREATED_BY"],
      usuario_migracion,
      Time.now,
      customer_brand["BUSINESS_SUBSIDIARY_HIERARCHY_STRUCTURE_ID"].to_s.empty? ? nil : uuid(customer_brand["BUSINESS_SUBSIDIARY_HIERARCHY_STRUCTURE_ID"]),
      customer_brand["EXTERNAL_ID"].to_s.empty? ? nil : customer_brand["EXTERNAL_ID"],
      customer_brand["DESCRIPTION"].to_s.empty? ? nil : customer_brand["DESCRIPTION"]
    ]

    "INSERT INTO core.customers_brands (#{columnas.join(', ')}) " \
      "VALUES (#{valores.map { |valor| literal(valor) }.join(', ')});"
  end

  def insert_sub_brand(sub_brand, customer_brand_id, marca_id)
    columnas = %w[
      sub_brand_id name short_name description brand_id cat_brand_product_type_id
      object_status_id created_by updated_by created_at external_id customer_brand_id
      cat_political_entity_type_id bra_id_external
    ]
    valores = [
      uuid(sub_brand["SUB_BRAND_ID"]),
      sub_brand["BRA_NAME"],
      sub_brand["BRA_SHORT_NAME"],
      sub_brand["BRA_LONG_NAME"],
      marca_id,
      uuid(sub_brand["CAT_BRAND_PRODUCT_TYPE_ID"]),
      uuid(sub_brand["OBJECT_STATUS_ID"]),
      sub_brand["CREATED_BY"],
      usuario_migracion,
      Time.now,
      sub_brand["EXTERNAL_ID"],
      customer_brand_id,
      sub_brand["CAT_POLITICAL_ENTITY_TYPE"].to_s.empty? ? nil : uuid(sub_brand["CAT_POLITICAL_ENTITY_TYPE"]),
      sub_brand["BRA_ID_EXTERNAL"].to_i
    ]

    "INSERT INTO core.sub_brands (#{columnas.join(', ')}) " \
      "VALUES (#{valores.map { |valor| literal(valor) }.join(', ')});"
  end

  def sentencias_insert(base, pares)
    marca_id = marca_insert(base)
    if marca_id.nil?
      raise ErrorMigracion, "No existe en core.brands ni #{MARCA_SIN_MARCA} ni #{MARCA_ALTERNA}"
    end

    sentencias = []
    pares.map do |par|
      [uuid(par[:customer_brand]["CUSTOMER_ID"]), uuid(par[:customer_brand]["SUBSIDIARY_ID"])]
    end.uniq.each do |customer_id, subsidiary_id|
      shared = sentencia_shared(base, customer_id, subsidiary_id)
      sentencias << shared if shared
    end

    pares.each do |par|
      par[:customer_brand_id] = SecureRandom.uuid
      sentencias << insert_customer_brand(par[:customer_brand], par[:customer_brand_id], marca_id)
    end
    pares.each do |par|
      sentencias << insert_sub_brand(par[:sub], par[:customer_brand_id], marca_id)
    end

    sentencias
  end

  def insert_customer_brand_idempotente(customer_brand, customer_brand_id, marca_id)
    customer_id = uuid(customer_brand["CUSTOMER_ID"])
    subsidiary_id = uuid(customer_brand["SUBSIDIARY_ID"])
    columnas = %w[
      customer_brand_id brand_id customer_id subsidiary_id object_status_id
      created_by updated_by created_at business_subsidiary_hierarchy_structure_id external_id description
    ]
    valores = [
      customer_brand_id,
      marca_id,
      customer_id,
      subsidiary_id,
      uuid(customer_brand["OBJECT_STATUS_ID"]),
      customer_brand["CREATED_BY"],
      usuario_migracion,
      Time.now,
      customer_brand["BUSINESS_SUBSIDIARY_HIERARCHY_STRUCTURE_ID"].to_s.empty? ? nil : uuid(customer_brand["BUSINESS_SUBSIDIARY_HIERARCHY_STRUCTURE_ID"]),
      customer_brand["EXTERNAL_ID"].to_s.empty? ? nil : customer_brand["EXTERNAL_ID"],
      customer_brand["DESCRIPTION"].to_s.empty? ? nil : customer_brand["DESCRIPTION"]
    ]

    "INSERT INTO core.customers_brands (#{columnas.join(', ')}) " \
      "SELECT #{valores.map { |valor| literal(valor) }.join(', ')} " \
      "WHERE NOT EXISTS (" \
      "SELECT 1 FROM core.customers_brands " \
      "WHERE customer_id = #{literal(customer_id)} " \
      "AND subsidiary_id = #{literal(subsidiary_id)} " \
      "AND brand_id = #{literal(marca_id)}" \
      ");"
  end

  def update_customer_brand_updated_by(customer_brand, marca_id)
    customer_id = uuid(customer_brand["CUSTOMER_ID"])
    subsidiary_id = uuid(customer_brand["SUBSIDIARY_ID"])

    "UPDATE core.customers_brands " \
      "SET updated_by = #{literal(usuario_migracion)} " \
      "WHERE customer_id = #{literal(customer_id)} " \
      "AND subsidiary_id = #{literal(subsidiary_id)} " \
      "AND brand_id = #{literal(marca_id)};"
  end

  def insert_sub_brand_idempotente(sub_brand, customer_brand, marca_id)
    sub_brand_id = uuid(sub_brand["SUB_BRAND_ID"])
    customer_id = uuid(customer_brand["CUSTOMER_ID"])
    subsidiary_id = uuid(customer_brand["SUBSIDIARY_ID"])
    customer_brand_expr = "(SELECT customer_brand_id FROM core.customers_brands " \
                          "WHERE customer_id = #{literal(customer_id)} " \
                          "AND subsidiary_id = #{literal(subsidiary_id)} " \
                          "AND brand_id = #{literal(marca_id)} " \
                          "ORDER BY created_at ASC LIMIT 1)"

    columnas = %w[
      sub_brand_id name short_name description brand_id cat_brand_product_type_id
      object_status_id created_by updated_by created_at external_id customer_brand_id
      cat_political_entity_type_id bra_id_external
    ]
    valores = [
      literal(sub_brand_id),
      literal(sub_brand["BRA_NAME"]),
      literal(sub_brand["BRA_SHORT_NAME"]),
      literal(sub_brand["BRA_LONG_NAME"]),
      literal(marca_id),
      literal(uuid(sub_brand["CAT_BRAND_PRODUCT_TYPE_ID"])),
      literal(uuid(sub_brand["OBJECT_STATUS_ID"])),
      literal(sub_brand["CREATED_BY"]),
      literal(usuario_migracion),
      literal(Time.now),
      literal(sub_brand["EXTERNAL_ID"]),
      customer_brand_expr,
      literal(sub_brand["CAT_POLITICAL_ENTITY_TYPE"].to_s.empty? ? nil : uuid(sub_brand["CAT_POLITICAL_ENTITY_TYPE"])),
      literal(sub_brand["BRA_ID_EXTERNAL"].to_i)
    ]

    "INSERT INTO core.sub_brands (#{columnas.join(', ')}) " \
      "SELECT #{valores.join(', ')} " \
      "WHERE NOT EXISTS (" \
      "SELECT 1 FROM core.sub_brands WHERE sub_brand_id = #{literal(sub_brand_id)}" \
      ");"
  end

  def update_sub_brand_updated_by(sub_brand, customer_brand, marca_id)
    sub_brand_id = uuid(sub_brand["SUB_BRAND_ID"])
    customer_id = uuid(customer_brand["CUSTOMER_ID"])
    subsidiary_id = uuid(customer_brand["SUBSIDIARY_ID"])

    "UPDATE core.sub_brands " \
      "SET customer_brand_id = (" \
      "SELECT customer_brand_id FROM core.customers_brands " \
      "WHERE customer_id = #{literal(customer_id)} " \
      "AND subsidiary_id = #{literal(subsidiary_id)} " \
      "AND brand_id = #{literal(marca_id)} " \
      "ORDER BY created_at ASC LIMIT 1), " \
      "updated_by = #{literal(usuario_migracion)} " \
      "WHERE sub_brand_id = #{literal(sub_brand_id)};"
  end

  def sentencias_migracion_directa
    marca_id = MARCA_SIN_MARCA
    pares = pares_fuente
    sentencias = []

    pares.each do |par|
      customer_brand_id = SecureRandom.uuid
      sentencias << insert_customer_brand_idempotente(par[:customer_brand], customer_brand_id, marca_id)
      sentencias << update_customer_brand_updated_by(par[:customer_brand], marca_id)
    end
    pares.each do |par|
      sentencias << insert_sub_brand_idempotente(par[:sub], par[:customer_brand], marca_id)
      sentencias << update_sub_brand_updated_by(par[:sub], par[:customer_brand], marca_id)
    end

    sentencias
  end

  def sentencias_update(base)
    requeridos = {
      SB_68159 => %w[68159 45661],
      SB_67226 => %w[67226],
      SB_63005 => %w[63005],
      SB_62890 => %w[62890],
      SB_62097 => %w[62097],
      SB_62084 => %w[62084]
    }
    problemas = requeridos.filter_map do |sub_brand_id, externos|
      fila = sub_brand_existente(base, sub_brand_id)
      if fila.nil?
        "#{externos.first} (no existe sub_brand_id #{sub_brand_id})"
      elsif !externos.include?(fila["EXTERNAL_ID"])
        "#{externos.first} (sub_brand_id #{sub_brand_id} tiene external_id #{fila['EXTERNAL_ID']})"
      end
    end
    unless problemas.empty?
      raise ErrorMigracion,
            "No se puede actualizar; usa insertar_marcas.rb. Detalle: #{problemas.join('; ')}"
    end

    customer_brand_ids = [CB_68159, CB_67226, CB_63005, CB_62890, CB_62097, CB_62084]
    existentes = base.consultar(
      "select customer_brand_id from core.customers_brands where customer_brand_id in (#{customer_brand_ids.map { |id| literal(id) }.join(', ')})"
    ).map { |fila| fila["CUSTOMER_BRAND_ID"] }
    faltantes = customer_brand_ids - existentes
    unless faltantes.empty?
      raise ErrorMigracion,
            "No existen los customer_brand_id requeridos: #{faltantes.join(', ')}. Usa insertar_marcas.rb."
    end

    if base.consultar("select customer_id from core.customers where customer_id = $1", [CLIENTE_POSADAS]).empty?
      raise ErrorMigracion, "No existe el cliente #{CLIENTE_POSADAS}"
    end

    sentencias = []
    shared = sentencia_shared_nacional(base, CLIENTE_POSADAS)
    sentencias << shared if shared

    sentencias << "UPDATE core.sub_brands " \
                  "SET external_id = '68159', " \
                  "name = 'TENIS CHARLY', " \
                  "short_name = 'TENCHA', " \
                  "description = 'TENIS CHARLY', " \
                  "brand_id = #{literal(MARCA_SIN_MARCA)}, " \
                  "customer_brand_id = #{literal(CB_68159)}, " \
                  "updated_by = #{literal(usuario_migracion)} " \
                  "WHERE sub_brand_id = #{literal(SB_68159)} AND external_id = '45661';"

    {
      SB_67226 => CB_67226,
      SB_63005 => CB_63005,
      SB_62890 => CB_62890,
      SB_62097 => CB_62097,
      SB_62084 => CB_62084
    }.each do |sub_brand_id, customer_brand_id|
      sentencias << "UPDATE core.sub_brands " \
                    "SET customer_brand_id = #{literal(customer_brand_id)}, " \
                    "updated_by = #{literal(usuario_migracion)} " \
                    "WHERE sub_brand_id = #{literal(sub_brand_id)};"
    end

    sentencias
  end

  def aplicar(base, sentencias)
    base.conexion.transaction do
      sentencias.each { |sql| base.ejecutar(sql) }
    end
  end

  def escribir_sql(ruta, sentencias)
    FileUtils.mkdir_p(File.dirname(ruta))
    encabezado = [
      "-- Migración de marcas y sub-marcas",
      "-- Fecha: #{fecha_migracion}",
      "-- updated_by: #{usuario_migracion}"
    ]
    contenido = (encabezado + ["BEGIN;"] + sentencias + ["COMMIT;"]).join("\n")
    File.write(ruta, "#{contenido}\n")
    puts "SQL generado: #{ruta}"
  end

  def imprimir_comparacion(comparacion)
    puts "Marcas.txt: #{comparacion[:total_marcas]} registros (#{comparacion[:unicos_marcas]} external_id únicos)"
    puts "DSM (consulta): #{comparacion[:total_dsm]} registros (#{comparacion[:unicos_dsm]} external_id únicos)"
    faltantes = comparacion[:faltan]
    puts "Faltan en DSM: #{faltantes.size}#{faltantes.empty? ? '' : " -> #{faltantes.join(', ')}"}"
    puts "Sobran en DSM: #{comparacion[:sobran].size}"
    duplicados = comparacion[:duplicados_dsm]
    if duplicados.empty?
      puts "external_id duplicados en DSM: 0"
    else
      puts "external_id duplicados en DSM: #{duplicados.map { |externo, cantidad| "#{externo} (#{cantidad})" }.join(', ')}"
    end
    puts "Diferencias de nombre/short_name: #{comparacion[:diferencias].size}"
  end

  def detalle_faltantes(base, registros_marcas, faltan)
    fuente = pares_fuente.to_h { |par| [par[:sub]["EXTERNAL_ID"], par] }
    marcas_por_externo = registros_marcas.group_by { |fila| fila["EXTERNAL_ID"] }
    faltan.map do |externo|
      par = fuente[externo]
      sub_brand_id = par && uuid(par[:sub]["SUB_BRAND_ID"])
      actual = sub_brand_id && sub_brand_existente(base, sub_brand_id)
      if par.nil?
        situacion = "NO EXISTE EN core.sub_brands y no está en los archivos de entrada"
        accion = "SIN DATOS PARA INSERTAR"
      elsif actual.nil?
        situacion = "NO EXISTE EN core.sub_brands"
        accion = "INSERT"
      elsif actual["EXTERNAL_ID"] == externo
        situacion = "EXISTE en core.sub_brands, pero no aparece en la consulta (subsidiaria/shared_customers)"
        accion = "UPDATE customer_brand_id / shared_customers"
      else
        situacion = "EXISTE el sub_brand_id, pero con external_id #{actual['EXTERNAL_ID']}"
        accion = "UPDATE external_id/customer_brand_id"
      end

      sugerencia = if par.nil?
                     "Conseguir los datos en los archivos de entrada"
                   elsif actual.nil?
                     "INSERT: no existe el sub_brand_id"
                   elsif actual["EXTERNAL_ID"] != externo
                     SUGERENCIAS[sub_brand_id] || "UPDATE external_id y customer_brand_id"
                   else
                     SUGERENCIAS[sub_brand_id] || "UPDATE customer_brand_id / shared_customers"
                   end

      coincidencias = []
      if actual && actual["EXTERNAL_ID"] != externo
        coincidencias = (marcas_por_externo[actual["EXTERNAL_ID"]] || []).map do |fila|
          {
            external_id: fila["EXTERNAL_ID"],
            sub_brand: fila["SUB_BRAND"],
            bra_id_external: fila["BRA_ID_EXTERNAL"],
            nombre: fila["SB_NAME"],
            short_name: fila["SB_SHORT_NAME"],
            subsidiary_number: fila["SUBSIDIARY_NUMBER"],
            subsidiary_name: fila["SUBSIDIARY_NAME"]
          }
        end
      end

      {
        external_id: externo,
        bra_id_external: par && par[:sub]["BRA_ID_EXTERNAL"],
        nombre: par && par[:sub]["BRA_NAME"],
        short_name: par && par[:sub]["BRA_SHORT_NAME"],
        sub_brand_id_dsm: actual && uuid(actual["SUB_BRAND_ID"]),
        external_id_dsm: actual && actual["EXTERNAL_ID"],
        customer_brand_id_dsm: actual && actual["CUSTOMER_BRAND_ID"],
        situacion: situacion,
        accion: accion,
        sugerencia: sugerencia,
        coincidencias_marcas: coincidencias
      }
    end
  end

  def imprimir_detalle_faltantes(detalle)
    return if detalle.empty?

    puts "\nDetalle de faltantes:"
    detalle.each do |d|
      puts "  #{d[:external_id]} | #{d[:nombre]} | #{d[:situacion]}"
      puts "    Qué hacer: #{d[:sugerencia]}"
      next if d[:external_id_dsm].nil? || d[:external_id_dsm] == d[:external_id]

      if d[:coincidencias_marcas].empty?
        puts "    En Marcas.txt NO existe el external_id #{d[:external_id_dsm]}."
      else
        puts "    En Marcas.txt el external_id #{d[:external_id_dsm]} corresponde a:"
        d[:coincidencias_marcas].each do |c|
          puts "      sub_brand #{c[:sub_brand]} | bra #{c[:bra_id_external]} | " \
               "#{c[:nombre]} / #{c[:short_name]} | subsidiaria #{c[:subsidiary_number]} #{c[:subsidiary_name]}"
        end
      end
    end
  end

  def escribir_reporte_comparacion(base, comparacion, detalle)
    FileUtils.mkdir_p(DIR_REPORTES)

    csv_faltantes = File.join(DIR_REPORTES, "faltantes_en_dsm.csv")
    CSV.open(csv_faltantes, "w") do |csv|
      csv << %w[EXTERNAL_ID BRA_ID_EXTERNAL SB_NAME SB_SHORT_NAME SUB_BRAND_ID_DSM EXTERNAL_ID_DSM CUSTOMER_BRAND_ID_DSM SITUACION ACCION QUE_HACER MARCAS_TXT_EXTERNAL_ID MARCAS_TXT_SUB_BRAND MARCAS_TXT_BRA_ID_EXTERNAL MARCAS_TXT_SB_NAME MARCAS_TXT_SB_SHORT_NAME MARCAS_TXT_SUBSIDIARY]
      detalle.each do |d|
        coincidencias = d[:coincidencias_marcas]
        csv << [d[:external_id], d[:bra_id_external], d[:nombre], d[:short_name],
                d[:sub_brand_id_dsm], d[:external_id_dsm], d[:customer_brand_id_dsm],
                d[:situacion], d[:accion], d[:sugerencia],
                coincidencias.map { |c| c[:external_id] }.join("; "),
                coincidencias.map { |c| c[:sub_brand] }.join("; "),
                coincidencias.map { |c| c[:bra_id_external] }.join("; "),
                coincidencias.map { |c| c[:nombre] }.join("; "),
                coincidencias.map { |c| c[:short_name] }.join("; "),
                coincidencias.map { |c| "#{c[:subsidiary_number]} #{c[:subsidiary_name]}" }.join("; ")]
      end
    end

    csv_diferencias = File.join(DIR_REPORTES, "diferencias_nombres.csv")
    CSV.open(csv_diferencias, "w") do |csv|
      csv << %w[EXTERNAL_ID BRA_ID_EXTERNAL NOMBRE_ITHIC NOMBRE_DSM SHORT_ITHIC SHORT_DSM]
      comparacion[:diferencias].each do |d|
        csv << [d[:external_id], d[:bra_id_external], d[:nombre_ithic], d[:nombre_dsm],
                d[:short_ithic], d[:short_dsm]]
      end
    end

    lineas = []
    lineas << "# Comparación de marcas/submarcas ITHIC vs DSM"
    lineas << ""
    lineas << "- Archivo fuente: `data/entrada/marcas/Marcas.txt`"
    lineas << "- Consulta DSM: `core.sub_brands` con `subsidiary_number = 0`"
    lineas << "- Fecha: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    lineas << "- Conexión: `#{ENV['CONNECTION_STRING']}` / usuario `#{ENV['USER']}`"
    lineas << ""
    lineas << "## Resumen"
    lineas << ""
    lineas << "| Métrica | Valor |"
    lineas << "| --- | ---: |"
    lineas << "| Registros en Marcas.txt | #{comparacion[:total_marcas]} |"
    lineas << "| Registros devueltos por la consulta DSM | #{comparacion[:total_dsm]} |"
    lineas << "| external_id únicos en Marcas.txt | #{comparacion[:unicos_marcas]} |"
    lineas << "| external_id únicos en DSM | #{comparacion[:unicos_dsm]} |"
    lineas << "| Faltan en DSM | #{comparacion[:faltan].size} |"
    lineas << "| Sobran en DSM | #{comparacion[:sobran].size} |"
    lineas << "| external_id duplicados en DSM | #{comparacion[:duplicados_dsm].size} |"
    lineas << "| Diferencias de nombre/short_name | #{comparacion[:diferencias].size} |"
    lineas << ""

    cuadra = comparacion[:faltan].empty? && comparacion[:sobran].empty? && comparacion[:duplicados_dsm].empty?
    lineas << "## Resultado: #{cuadra ? 'CUADRA' : 'NO CUADRA'}"
    lineas << ""

    lineas << "## external_id faltantes en DSM"
    lineas << ""
    lineas << "| external_id | bra_id_external | Nombre | Short | Situación | Qué hacer |"
    lineas << "| ---: | ---: | --- | --- | --- | --- |"
    detalle.each do |d|
      lineas << "| #{d[:external_id]} | #{d[:bra_id_external]} | #{d[:nombre]} | #{d[:short_name]} | #{d[:situacion]} | #{d[:sugerencia]} |"
    end
    lineas << ""

    coincidencias = detalle.select { |d| d[:coincidencias_marcas].any? }
    unless coincidencias.empty?
      lineas << "## Coincidencias encontradas en Marcas.txt"
      lineas << ""
      coincidencias.each do |d|
        lineas << "### external_id #{d[:external_id]}"
        lineas << ""
        lineas << "En DSM el sub_brand_id `#{d[:sub_brand_id_dsm]}` tiene el external_id `#{d[:external_id_dsm]}`. En `Marcas.txt`, ese external_id corresponde a:"
        lineas << ""
        lineas << "| external_id | sub_brand | bra_id_external | Nombre | Short | Subsidiaria |"
        lineas << "| ---: | --- | ---: | --- | --- | --- |"
        d[:coincidencias_marcas].each do |c|
          lineas << "| #{c[:external_id]} | #{c[:sub_brand]} | #{c[:bra_id_external]} | #{c[:nombre]} | #{c[:short_name]} | #{c[:subsidiary_number]} #{c[:subsidiary_name]} |"
        end
        lineas << ""
      end
    end

    sin_coincidencia = detalle.select do |d|
      d[:external_id_dsm] && d[:external_id_dsm] != d[:external_id] && d[:coincidencias_marcas].empty?
    end
    unless sin_coincidencia.empty?
      lineas << "## external_id de DSM sin coincidencia en Marcas.txt"
      lineas << ""
      sin_coincidencia.each do |d|
        lineas << "- `#{d[:external_id]}` tiene en DSM el external_id `#{d[:external_id_dsm]}`, que no existe en `Marcas.txt`."
      end
      lineas << ""
    end

    if shared_nacional(base, CLIENTE_POSADAS).nil?
      lineas << "## Aviso sobre GRUPO POSADAS"
      lineas << ""
      lineas << "El cliente `#{CLIENTE_POSADAS}` no tiene `shared_customer` en **NACIONAL**. La consulta obtiene la subsidiaria desde `core.shared_customers`, así que los 5 sub_brands de Posadas no aparecerán en `subsidiary_number = 0` aunque existan en `core.sub_brands`."
      lineas << ""
    end

    unless comparacion[:duplicados_dsm].empty?
      lineas << "## external_id duplicados en DSM"
      lineas << ""
      comparacion[:duplicados_dsm].each do |externo, cantidad|
        lineas << "- `#{externo}` aparece #{cantidad} veces."
      end
      lineas << ""
    end

    lineas << "## Archivos"
    lineas << ""
    lineas << "- `faltantes_en_dsm.csv`"
    lineas << "- `diferencias_nombres.csv`"
    lineas << ""

    ruta = File.join(DIR_REPORTES, "comparacion_marcas.md")
    File.write(ruta, lineas.join("\n") + "\n")
    ruta
  end

  def verificar(base)
    comparacion = comparar(marcas, dsm(base))
    puts
    imprimir_comparacion(comparacion)
    comparacion[:faltan].empty? && comparacion[:sobran].empty? && comparacion[:duplicados_dsm].empty?
  end

  def imprimir_sentencias(sentencias)
    puts "\nSentencias: #{sentencias.size}"
    sentencias.each_with_index do |sql, indice|
      puts "\n-- #{indice + 1}"
      puts sql
    end
  end

  def parsear_opciones(argv, nombre_script, accion: "Marcas y SubMarcas")
    opciones = { ejecutar: false, sql: ruta_sql_por_defecto(accion) }
    parser = OptionParser.new do |opts|
      opts.banner = "Uso: bundle exec ruby scripts/migracion_brands_and_customerbrands/#{nombre_script} [opciones]"
      opts.on("--ejecutar", "Aplica las sentencias en una transacción") { opciones[:ejecutar] = true }
      opts.on("--sql RUTA", "Escribe las sentencias en un archivo SQL (por defecto: #{opciones[:sql]})") { |ruta| opciones[:sql] = ruta }
      opts.on("--sin-sql", "No escribe archivo SQL") { opciones[:sql] = nil }
      opts.on("-h", "--help", "Muestra esta ayuda") do
        puts opts
        exit(0)
      end
    end
    parser.parse!(argv)
    opciones
  end

  def describir_conexion
    puts "Host: #{ENV['CONNECTION_STRING']} | base: #{ENV['DATABASE']} | usuario: #{ENV['USER']} | esquema: #{ENV['SCHEMA']}"
  end
end
