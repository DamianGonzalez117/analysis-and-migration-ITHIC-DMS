#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "optparse"
require "pathname"

RAIZ_PROYECTO = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(RAIZ_PROYECTO, "lib"))
require "ithic"

module ComparacionDescuentosTipoPauta
  class ErrorReporte < StandardError; end

  ARCHIVO_POR_DEFECTO = File.join(
    RAIZ_PROYECTO, "data", "entrada", "descuentos_tipo_pauta", "Descuentos_tipo_pauta_26.txt"
  )
  DIR_REPORTES = File.join(RAIZ_PROYECTO, "data", "reportes", "descuentos_tipo_pauta")
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
    base = nil

    begin
      base = Ithic::BaseDatos.desde(Ithic::Configuracion.new)
      describir_conexion
      puts "Archivo ITHIC: #{archivo} (año #{anio})"

      fuente = Ithic::LectorTxt.leer(archivo)
      filas_dsm = base.consultar(CONSULTA, [anio.to_s])
      resultado = comparar(fuente.filas, filas_dsm, archivo: archivo, anio: anio)

      imprimir_resultado(resultado)
      rutas = escribir_reportes(resultado)

      puts "\nReportes:"
      puts "  - #{rutas[:md]}"
      puts "  - #{rutas[:csv]}"
      puts(resultado[:cuadra] ? "Resultado: CUADRA" : "Resultado: NO CUADRA")
      resultado[:cuadra] ? 0 : 2
    rescue Ithic::ErrorIthic, PG::Error, OptionParser::ParseError, ErrorReporte => e
      warn "\nERROR: #{e.message}"
      1
    ensure
      base&.cerrar
    end
  end

  def parsear(argv)
    opciones = { archivo: nil }
    parser = OptionParser.new do |opts|
      opts.banner = "Uso: bundle exec ruby scripts/migracion_descuentos_tipo_pauta/comparar_descuentos_tipo_pauta.rb [ARCHIVO]"
      opts.on("-a", "--archivo RUTA", "Archivo ITHIC separado por |") { |ruta| opciones[:archivo] = ruta }
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

  def comparar(filas_ithic, filas_dsm, archivo:, anio:)
    ithic_por_clave = filas_ithic.group_by { |fila| clave(fila) }
    dsm_por_clave = filas_dsm.group_by { |fila| clave(fila) }

    valores = []
    solo_ithic = []
    solo_dsm = []

    (ithic_por_clave.keys | dsm_por_clave.keys).each do |clave_registro|
      filas_ithic_clave = ithic_por_clave.fetch(clave_registro, [])
      filas_dsm_clave = dsm_por_clave.fetch(clave_registro, [])
      [filas_ithic_clave.size, filas_dsm_clave.size].max.times do |indice|
        fila_ithic = filas_ithic_clave[indice]
        fila_dsm = filas_dsm_clave[indice]

        if fila_ithic.nil?
          solo_dsm << construir_diferencia(clave_registro, nil, fila_dsm, [], :solo_dsm)
        elsif fila_dsm.nil?
          solo_ithic << construir_diferencia(clave_registro, fila_ithic, nil, [], :solo_ithic)
        else
          campos = CAMPOS.filter_map do |campo|
            valor_ithic = valor_campo(fila_ithic, campo)
            valor_dsm = valor_campo(fila_dsm, campo)
            [campo, valor_ithic, valor_dsm] unless valor_ithic == valor_dsm
          end
          unless campos.empty?
            valores << construir_diferencia(clave_registro, fila_ithic, fila_dsm, campos, :valores)
          end
        end
      end
    end

    contratos_ithic = indexar_contratos(filas_ithic)
    contratos_dsm = indexar_contratos(filas_dsm)
    contratos_con_diferencia = (contratos_ithic.keys | contratos_dsm.keys).filter_map do |clave_contrato|
      contrato_ithic = contratos_ithic[clave_contrato]
      contrato_dsm = contratos_dsm[clave_contrato]
      cantidad_ithic = contrato_ithic ? contrato_ithic[:cantidad] : 0
      cantidad_dsm = contrato_dsm ? contrato_dsm[:cantidad] : 0
      next if cantidad_ithic == cantidad_dsm

      base_contrato = contrato_ithic || contrato_dsm
      {
        contract_id: base_contrato[:contract_id],
        external_contract: base_contrato[:external_contract],
        cantidad_ithic: cantidad_ithic,
        cantidad_dsm: cantidad_dsm
      }
    end

    por_campo = CAMPOS.to_h do |campo|
      [campo, valores.sum { |diferencia| diferencia[:campos].count { |nombre, _, _| nombre == campo } }]
    end
    direcciones = CAMPOS.to_h do |campo|
      conteo = Hash.new(0)
      valores.each do |diferencia|
        diferencia[:campos].each do |nombre, valor_ithic, valor_dsm|
          conteo["#{valor_ithic}->#{valor_dsm}"] += 1 if nombre == campo
        end
      end
      [campo, conteo]
    end

    {
      archivo: archivo,
      anio: anio,
      total_ithic: filas_ithic.size,
      total_dsm: filas_dsm.size,
      claves_ithic: ithic_por_clave.size,
      claves_dsm: dsm_por_clave.size,
      contratos_ithic: contratos_ithic.size,
      contratos_dsm: contratos_dsm.size,
      coincidencias: (ithic_por_clave.keys & dsm_por_clave.keys).size,
      duplicados_ithic: ithic_por_clave.count { |_, filas| filas.size > 1 },
      duplicados_dsm: dsm_por_clave.count { |_, filas| filas.size > 1 },
      solo_ithic: ordenar(solo_ithic),
      solo_dsm: ordenar(solo_dsm),
      valores: ordenar(valores),
      por_campo: por_campo,
      direcciones: direcciones,
      contratos_con_diferencia: contratos_con_diferencia.sort_by { |contrato| contrato[:external_contract].to_i },
      cuadra: valores.empty? && solo_ithic.empty? && solo_dsm.empty? &&
              ithic_por_clave.count { |_, filas| filas.size > 1 }.zero? &&
              dsm_por_clave.count { |_, filas| filas.size > 1 }.zero?
    }
  end

  def construir_diferencia(clave_registro, fila_ithic, fila_dsm, campos, tipo)
    fila_base = fila_ithic || fila_dsm
    {
      clave: clave_registro,
      contrato_id: id_canonico(fila_base["CONTRACT_ID"]),
      external_contract: valor_campo(fila_base, "EXTERNAL_CONTRACT"),
      descuento_id: id_canonico(fila_base["DISCOUNT_ID"]),
      external_discount: valor_campo(fila_base, "EXTERNAL_DISCOUNT"),
      nombre: nombre_legible((fila_ithic && fila_ithic["NAME_DISCOUNT"]) || fila_dsm["NAME_DISCOUNT"]),
      fila_ithic: fila_ithic,
      fila_dsm: fila_dsm,
      campos: campos,
      tipo: tipo
    }
  end

  def indexar_contratos(filas)
    filas.group_by { |fila| normalizar_id(fila["CONTRACT_ID"]) }.transform_values do |filas_contrato|
      fila = filas_contrato.first
      {
        contract_id: id_canonico(fila["CONTRACT_ID"]),
        external_contract: valor_campo(fila, "EXTERNAL_CONTRACT"),
        cantidad: filas_contrato.size
      }
    end
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

  def ordenar(diferencias)
    diferencias.sort_by do |diferencia|
      [diferencia[:external_contract].to_i, diferencia[:external_discount].to_i, diferencia[:nombre]]
    end
  end

  def imprimir_resultado(resultado)
    puts "Registros ITHIC: #{resultado[:total_ithic]} " \
         "(#{resultado[:claves_ithic]} claves únicas, #{resultado[:contratos_ithic]} contratos)"
    puts "Registros DSM: #{resultado[:total_dsm]} " \
         "(#{resultado[:claves_dsm]} claves únicas, #{resultado[:contratos_dsm]} contratos)"
    puts "Coincidencias por clave: #{resultado[:coincidencias]}"
    puts "Solo en ITHIC: #{resultado[:solo_ithic].size}"
    puts "Solo en DSM: #{resultado[:solo_dsm].size}"
    puts "Duplicados de clave en ITHIC: #{resultado[:duplicados_ithic]}"
    puts "Duplicados de clave en DSM: #{resultado[:duplicados_dsm]}"
    puts "Descuentos con diferencias TF/SR/PI: #{resultado[:valores].size} " \
         "(#{resultado[:por_campo].values.sum} diferencias de campo)"
    CAMPOS.each do |campo|
      detalle = resultado[:direcciones][campo].map { |direccion, cantidad| "#{direccion}: #{cantidad}" }
      puts "  #{campo}: #{resultado[:por_campo][campo]}#{detalle.empty? ? '' : " (#{detalle.join(', ')})"}"
    end
    puts "Contratos con diferencia en cantidad de descuentos: #{resultado[:contratos_con_diferencia].size}"
    resultado[:contratos_con_diferencia].each do |contrato|
      puts "  #{contrato[:contract_id]} | externo #{contrato[:external_contract]} | " \
           "ITHIC #{contrato[:cantidad_ithic]} vs DSM #{contrato[:cantidad_dsm]}"
    end

    total = resultado[:valores].size + resultado[:solo_ithic].size + resultado[:solo_dsm].size
    if total.zero?
      puts "\nSin diferencias."
      return
    end

    puts "\nDetalle de diferencias (contract_id | discount_id | externos | nombre | diferencia):"
    resultado[:valores].each do |diferencia|
      puts "  #{diferencia[:contrato_id]} | #{diferencia[:descuento_id]} | " \
           "#{diferencia[:external_contract]}/#{diferencia[:external_discount]} | " \
           "#{diferencia[:nombre]} | #{describir_diferencias(diferencia)}"
    end
    resultado[:solo_ithic].each do |diferencia|
      puts "  #{diferencia[:contrato_id]} | #{diferencia[:descuento_id]} | " \
           "#{diferencia[:external_contract]}/#{diferencia[:external_discount]} | " \
           "#{diferencia[:nombre]} | #{describir_diferencias(diferencia)}"
    end
    resultado[:solo_dsm].each do |diferencia|
      puts "  #{diferencia[:contrato_id]} | #{diferencia[:descuento_id]} | " \
           "#{diferencia[:external_contract]}/#{diferencia[:external_discount]} | " \
           "#{diferencia[:nombre]} | #{describir_diferencias(diferencia)}"
    end
  end

  def describir_diferencias(diferencia)
    case diferencia[:tipo]
    when :solo_ithic
      "No existe en DSM (solo en ITHIC)"
    when :solo_dsm
      "No existe en ITHIC (solo en DSM)"
    else
      diferencia[:campos].map do |campo, valor_ithic, valor_dsm|
        "#{campo}: ITHIC=#{mostrar(valor_ithic)} DSM=#{mostrar(valor_dsm)}"
      end.join("; ")
    end
  end

  def mostrar(valor)
    texto = valor.to_s.strip
    texto.empty? ? "—" : texto
  end

  def escribir_reportes(resultado)
    FileUtils.mkdir_p(DIR_REPORTES)
    sufijo = format("%02d", resultado[:anio] % 100)
    ruta_md = File.join(DIR_REPORTES, "comparacion_descuentos_tipo_pauta-#{sufijo}.md")
    ruta_csv = File.join(DIR_REPORTES, "diferencias_descuentos_tipo_pauta-#{sufijo}.csv")

    escribir_csv(resultado, ruta_csv)
    escribir_md(resultado, ruta_md, ruta_csv)

    { md: ruta_md, csv: ruta_csv }
  end

  def escribir_csv(resultado, ruta)
    CSV.open(ruta, "w") do |csv|
      csv << %w[
        TIPO_DIFERENCIA CONTRACT_ID EXTERNAL_CONTRACT DISCOUNT_ID EXTERNAL_DISCOUNT
        NAME_DISCOUNT TF_ITHIC TF_DSM SR_ITHIC SR_DSM PI_ITHIC PI_DSM DIFERENCIAS
      ]
      filas = resultado[:valores] + resultado[:solo_ithic] + resultado[:solo_dsm]
      filas.each do |diferencia|
        csv << [
          etiqueta_tipo(diferencia[:tipo]),
          diferencia[:contrato_id],
          diferencia[:external_contract],
          diferencia[:descuento_id],
          diferencia[:external_discount],
          diferencia[:nombre],
          valor_campo(diferencia[:fila_ithic], "TF"),
          valor_campo(diferencia[:fila_dsm], "TF"),
          valor_campo(diferencia[:fila_ithic], "SR"),
          valor_campo(diferencia[:fila_dsm], "SR"),
          valor_campo(diferencia[:fila_ithic], "PI"),
          valor_campo(diferencia[:fila_dsm], "PI"),
          describir_diferencias(diferencia)
        ]
      end
    end
  end

  def etiqueta_tipo(tipo)
    {
      valores: "VALORES",
      solo_ithic: "SOLO_ITHIC",
      solo_dsm: "SOLO_DSM"
    }.fetch(tipo)
  end

  def escribir_md(resultado, ruta, ruta_csv)
    lineas = []
    lineas << "# Comparación descuentos por tipo de pauta #{resultado[:anio]}"
    lineas << ""
    lineas << "- Archivo ITHIC: `#{ruta_relativa(resultado[:archivo])}`"
    lineas << "- Consulta DSM: `core.contracts` / `core.contract_discounts` / `core.guideline_types`"
    lineas << "- Año consultado: #{resultado[:anio]}"
    lineas << "- Fecha de ejecución: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
    lineas << "- Conexión: `#{ENV['CONNECTION_STRING']}` / base `#{ENV['DATABASE']}` / usuario `#{ENV['USER']}`"
    lineas << "- Resultado: **#{resultado[:cuadra] ? 'CUADRA' : 'NO CUADRA'}**"
    lineas << ""
    lineas << "## Resumen"
    lineas << ""
    lineas << "| Métrica | ITHIC | DSM | Diferencia |"
    lineas << "| --- | ---: | ---: | ---: |"
    lineas << "| Registros | #{resultado[:total_ithic]} | #{resultado[:total_dsm]} | #{resultado[:total_ithic] - resultado[:total_dsm]} |"
    lineas << "| Claves únicas (contract_id + discount_id) | #{resultado[:claves_ithic]} | #{resultado[:claves_dsm]} | #{resultado[:claves_ithic] - resultado[:claves_dsm]} |"
    lineas << "| Contratos | #{resultado[:contratos_ithic]} | #{resultado[:contratos_dsm]} | #{resultado[:contratos_ithic] - resultado[:contratos_dsm]} |"
    lineas << "| Coincidencias por clave | #{resultado[:coincidencias]} | #{resultado[:coincidencias]} | 0 |"
    lineas << "| Solo en ITHIC | #{resultado[:solo_ithic].size} | 0 | #{resultado[:solo_ithic].size} |"
    lineas << "| Solo en DSM | 0 | #{resultado[:solo_dsm].size} | #{resultado[:solo_dsm].empty? ? 0 : -resultado[:solo_dsm].size} |"
    lineas << "| Duplicados de clave | #{resultado[:duplicados_ithic]} | #{resultado[:duplicados_dsm]} | #{resultado[:duplicados_ithic] - resultado[:duplicados_dsm]} |"
    lineas << "| Descuentos con diferencias TF/SR/PI | #{resultado[:valores].size} | — | — |"
    lineas << ""
    lineas << "## Diferencias por campo"
    lineas << ""
    lineas << "| Campo | Diferencias | 1 → 0 | 0 → 1 | Otras |"
    lineas << "| --- | ---: | ---: | ---: | ---: |"
    CAMPOS.each do |campo|
      uno_cero = resultado[:direcciones][campo]["1->0"]
      cero_uno = resultado[:direcciones][campo]["0->1"]
      otras = resultado[:por_campo][campo] - uno_cero - cero_uno
      lineas << "| #{campo} | #{resultado[:por_campo][campo]} | #{uno_cero} | #{cero_uno} | #{otras} |"
    end
    lineas << ""
    lineas << "## Diferencias de valores TF/SR/PI"
    lineas << ""
    if resultado[:valores].empty?
      lineas << "Sin diferencias de valores."
    else
      lineas << "| CONTRACT_ID | EXTERNAL_CONTRACT | DISCOUNT_ID | EXTERNAL_DISCOUNT | NAME_DISCOUNT | " \
                "TF ITHIC | TF DSM | SR ITHIC | SR DSM | PI ITHIC | PI DSM | DIFERENCIAS |"
      lineas << "| --- | ---: | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"
      resultado[:valores].each do |diferencia|
        lineas << fila_md(diferencia)
      end
    end
    lineas << ""
    lineas << "## Descuentos solo en ITHIC"
    lineas << ""
    lineas.concat(tabla_solo(resultado[:solo_ithic], :ithic))
    lineas << ""
    lineas << "## Descuentos solo en DSM"
    lineas << ""
    lineas.concat(tabla_solo(resultado[:solo_dsm], :dsm))
    lineas << ""
    lineas << "## Contratos con diferencia en cantidad de descuentos"
    lineas << ""
    if resultado[:contratos_con_diferencia].empty?
      lineas << "Sin diferencias de cantidad por contrato."
    else
      lineas << "| CONTRACT_ID | EXTERNAL_CONTRACT | Descuentos ITHIC | Descuentos DSM | Diferencia |"
      lineas << "| --- | ---: | ---: | ---: | ---: |"
      resultado[:contratos_con_diferencia].each do |contrato|
        lineas << "| #{celda(contrato[:contract_id])} | #{celda(contrato[:external_contract])} | " \
                  "#{contrato[:cantidad_ithic]} | #{contrato[:cantidad_dsm]} | " \
                  "#{contrato[:cantidad_ithic] - contrato[:cantidad_dsm]} |"
      end
    end
    lineas << ""
    lineas << "## Archivos generados"
    lineas << ""
    lineas << "- `#{ruta_relativa(ruta_csv)}`"
    lineas << ""

    File.write(ruta, lineas.join("\n"))
  end

  def fila_md(diferencia)
    "| #{celda(diferencia[:contrato_id])} | #{celda(diferencia[:external_contract])} | " \
      "#{celda(diferencia[:descuento_id])} | #{celda(diferencia[:external_discount])} | " \
      "#{celda(diferencia[:nombre])} | " \
      "#{celda(mostrar(valor_campo(diferencia[:fila_ithic], 'TF')))} | " \
      "#{celda(mostrar(valor_campo(diferencia[:fila_dsm], 'TF')))} | " \
      "#{celda(mostrar(valor_campo(diferencia[:fila_ithic], 'SR')))} | " \
      "#{celda(mostrar(valor_campo(diferencia[:fila_dsm], 'SR')))} | " \
      "#{celda(mostrar(valor_campo(diferencia[:fila_ithic], 'PI')))} | " \
      "#{celda(mostrar(valor_campo(diferencia[:fila_dsm], 'PI')))} | " \
      "#{celda(describir_diferencias(diferencia))} |"
  end

  def tabla_solo(diferencias, lado)
    return ["Sin registros."] if diferencias.empty?

    lineas = [
      "| CONTRACT_ID | EXTERNAL_CONTRACT | DISCOUNT_ID | EXTERNAL_DISCOUNT | NAME_DISCOUNT | TF | SR | PI | TIPO_DIFERENCIA |",
      "| --- | ---: | --- | ---: | --- | ---: | ---: | ---: | --- |"
    ]
    diferencias.each do |diferencia|
      fila = lado == :ithic ? diferencia[:fila_ithic] : diferencia[:fila_dsm]
      lineas << "| #{celda(diferencia[:contrato_id])} | #{celda(diferencia[:external_contract])} | " \
                "#{celda(diferencia[:descuento_id])} | #{celda(diferencia[:external_discount])} | " \
                "#{celda(diferencia[:nombre])} | #{celda(mostrar(valor_campo(fila, 'TF')))} | " \
                "#{celda(mostrar(valor_campo(fila, 'SR')))} | #{celda(mostrar(valor_campo(fila, 'PI')))} | " \
                "#{describir_diferencias(diferencia)} |"
    end
    lineas
  end

  def celda(valor)
    valor.to_s.gsub("|", "\\|").gsub(/\r?\n/, " ")
  end

  def ruta_relativa(ruta)
    Pathname.new(ruta).relative_path_from(Pathname.new(RAIZ_PROYECTO)).to_s
  rescue ArgumentError
    ruta.to_s
  end
end

exit(ComparacionDescuentosTipoPauta.ejecutar(ARGV))
