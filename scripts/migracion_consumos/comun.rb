# frozen_string_literal: true

require "bigdecimal"
require "date"
require "json"
require "pathname"
require "securerandom"
require "set"

RAIZ_PROYECTO = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(RAIZ_PROYECTO, "lib"))

require "ithic"

module MigracionConsumos
  DIR_CONSUMOS = File.join(RAIZ_PROYECTO, "data", "entrada", "migracion", "consumos").freeze
  RUTA_CONSUMOS = File.join(DIR_CONSUMOS, "consumption_blocked_details.txt").freeze
  RUTA_MAPA = File.join(DIR_CONSUMOS, "mapa_catalogos.json").freeze

  OBJECT_STATUS_POR_DEFECTO = "1f0746ed-9ae6-4055-a641-efb4bf7d0a56" # CREADO
  CREADO_POR = "migracion@muhami.com"
  OBJECT_STATUS_VALIDOS = [
    OBJECT_STATUS_POR_DEFECTO,
    "fd702fb1-91ac-43a3-a305-ea24549d57cf", # ENVIADO A SAP
    "7d3b46bb-ded8-40ad-bb66-eecc09bbcc03", # NO ENVIADO A SAP
    "1f0746ed-9ae6-4055-a641-efb4bf7d0a57"  # ELIMINADO
  ].freeze

  # Sobrescrituras opcionales de estatus por external_id (vacío por defecto:
  # todo registro nuevo se inserta como CREADO).
  OBJECT_STATUS_POR_REGISTRO = {}.freeze

  TABLAS_CATALOGO = {
    "cce" => { tabla: "cat_cost_center_consumption", id: "cat_cost_center_consumption_id", archivo: "cat_cost_center_consumption.txt" },
    "art" => { tabla: "cat_accounting_record_types", id: "cat_accounting_record_type_id", archivo: "cat_accounting_record_types.txt" },
    "sales_type" => { tabla: "cat_sales_types", id: "cat_sale_type_id", archivo: "cat_sales_types.txt" },
    "sd" => { tabla: "cat_sales_details_types", id: "cat_sale_detail_type_id", archivo: "cat_sales_details_types.txt" }
  }.freeze

  # Filas del export con un campo extra o un "|" dentro de COMENTS (se
  # detectaron 4 anomalías en 122,268 registros).
  CORRECCIONES = {
    "13951" => { accion: :quitar, indice: 6 },
    "650" => { accion: :quitar, indice: 5 },
    "275440" => { accion: :quitar, indice: 3 },
    "373553" => { accion: :unir, indice: 5 }
  }.freeze

  module_function

  def conexion
    Ithic::BaseDatos.desde(Ithic::Configuracion.new)
  end

  def mapa_catalogos
    unless File.file?(RUTA_MAPA)
      raise Ithic::ErrorIthic, "Falta #{RUTA_MAPA}; ejecuta primero generar_mapa.rb"
    end

    JSON.parse(File.read(RUTA_MAPA))["catalogs"]
  end

  def leer_texto(ruta)
    datos = File.binread(ruta)
    utf8 = datos.dup.force_encoding("UTF-8")
    return utf8 if utf8.valid_encoding?

    datos.force_encoding("ISO-8859-1").encode("UTF-8")
  end

  def leer_catalogo(nombre)
    lineas = leer_texto(File.join(DIR_CONSUMOS, nombre)).split(/\r?\n/).reject { |linea| linea.strip.empty? }
    encabezado = lineas.first.split("|", -1).map(&:strip)
    filas = lineas[1..].map do |linea|
      valores = linea.split("|", -1)
      encabezado.zip(valores).to_h { |clave, valor| [clave, valor.to_s.strip] }
    end
    [encabezado, filas]
  end

  # Devuelve [registros, anomalias]. Cada registro es un Hash columna => valor.
  def parsear_consumos(ruta = RUTA_CONSUMOS)
    lineas = leer_texto(ruta).split(/\r?\n/, -1)
    encabezado = lineas.first.split("|", -1).map(&:strip)
    esperados = encabezado.size

    registros = []
    anomalias = []
    buffer = []
    campos = 0

    lineas[1..].each do |linea|
      linea = linea.delete_suffix("\r")
      next if buffer.empty? && linea.strip.empty?

      if buffer.empty?
        campos = linea.count("|") + 1
        buffer = [linea]
      else
        campos += linea.count("|")
        buffer << linea
      end
      next if campos < esperados

      partes = buffer.join("\n").split("|", -1)
      fila = armar_fila(encabezado, partes, anomalias)
      registros << fila if fila
      buffer = []
      campos = 0
    end

    unless buffer.empty?
      anomalias << { external_id: buffer.join("\n")[0, 60], campos: campos, texto: buffer.join("|")[0, 200] }
    end

    [registros, anomalias]
  end

  def armar_fila(encabezado, partes, anomalias)
    if partes.size != encabezado.size
      correccion = CORRECCIONES[partes.last.to_s.strip]
      if correccion && partes.size == encabezado.size + 1
        case correccion[:accion]
        when :quitar
          partes = partes.dup.tap { |copia| copia.delete_at(correccion[:indice]) }
        when :unir
          copia = partes.dup
          copia[correccion[:indice]] = "#{copia[correccion[:indice]]}|#{copia.delete_at(correccion[:indice] + 1)}"
          partes = copia
        end
        if partes.size == encabezado.size
          anomalias << { external_id: partes.last.to_s.strip, corregida: true, campos: encabezado.size + 1 }
        end
      end
    end

    if partes.size != encabezado.size
      anomalias << { external_id: partes.last.to_s.strip, campos: partes.size, texto: partes.join("|")[0, 200] }
      return nil
    end

    encabezado.zip(partes).to_h { |clave, valor| [clave, valor.to_s.strip] }
  end

  def uuid(valor)
    limpio = valor.to_s.strip.delete("-").downcase
    return nil if limpio.empty?
    return limpio unless limpio.match?(/\A[0-9a-f]{32}\z/)

    [limpio[0, 8], limpio[8, 4], limpio[12, 4], limpio[16, 4], limpio[20, 12]].join("-")
  end

  def entero(valor)
    limpio = valor.to_s.strip
    return nil if limpio.empty?
    return limpio.to_i if limpio.match?(/\A-?\d+\z/)

    limpio
  end

  def decimal(valor)
    limpio = valor.to_s.strip
    return nil if limpio.empty?

    BigDecimal(limpio)
  rescue ArgumentError
    limpio
  end

  def fecha(valor)
    limpio = valor.to_s.strip
    return nil if limpio.empty?

    Ithic::Normalizador::FORMATOS_FECHA.each do |formato|
      begin
        return Date.strptime(limpio, formato)
      rescue Date::Error
        next
      end
    end
    limpio
  end

  def booleano(valor)
    valor.to_s.strip == "1"
  end

  def normalizar_external_id(valor)
    valor.to_s.strip.sub(/\.0+\z/, "")
  end

  def estado_para(external_id)
    OBJECT_STATUS_POR_REGISTRO[external_id.to_s] || OBJECT_STATUS_POR_DEFECTO
  end
end
