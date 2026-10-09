# frozen_string_literal: true

require "csv"
require "pathname"

module Ithic
  Fuente = Struct.new(:ruta, :campos, :filas, keyword_init: true)

  module LectorTxt
    module_function

    BOM_UTF8 = "\xEF\xBB\xBF".b

    def leer(ruta)
      ruta = Pathname.new(ruta)
      raise ErrorFuente, "No existe el archivo: #{ruta}" unless ruta.file?

      contenido = decodificar(ruta)
      lineas = contenido.split(/\r\n|\n|\r/).reject { |linea| linea.strip.empty? }
      raise ErrorFuente, "El archivo está vacío: #{ruta}" if lineas.empty?

      tabla = CSV.parse(lineas.join("\n"), col_sep: "|", headers: true, liberal_parsing: true)
      encabezados = (tabla.headers || []).each_with_object({}) do |encabezado, mapa|
        mapa[encabezado] = encabezado.to_s.strip
      end
      campos = encabezados.values
      filas = tabla.map do |fila|
        fila.to_h.each_with_object({}) do |(clave, valor), resultado|
          resultado[encabezados[clave] || clave.to_s.strip] = valor.to_s.strip
        end
      end

      Fuente.new(ruta: ruta, campos: campos, filas: filas)
    end

    def decodificar(ruta)
      datos = ruta.binread
      if datos.start_with?(BOM_UTF8)
        return datos.byteslice(3..).force_encoding("UTF-8")
      end

      utf8 = datos.dup.force_encoding("UTF-8")
      return utf8 if utf8.valid_encoding?

      datos.force_encoding("ISO-8859-1").encode("UTF-8")
    end
  end
end
