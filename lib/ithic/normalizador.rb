# frozen_string_literal: true

require "bigdecimal"
require "date"

module Ithic
  module Normalizador
    FORMATOS_FECHA = ["%d/%m/%Y", "%Y/%m/%d", "%d-%m-%Y", "%Y-%m-%d"].freeze

    module_function

    def normalizar(tipo, valor)
      case (tipo || :texto).to_sym
      when :uuid then texto(valor).upcase
      when :uuid_postgres then uuid_postgres(valor)
      when :fecha then fecha_comparacion(valor)
      when :fecha_iso then fecha_iso(valor)
      when :decimal then decimal(valor)
      when :entero then entero(valor)
      else texto(valor)
      end
    end

    def texto(valor)
      valor.nil? ? "" : valor.to_s.strip
    end

    def uuid_postgres(valor)
      limpio = texto(valor).delete("-").downcase
      return limpio if limpio.length != 32

      [limpio[0, 8], limpio[8, 4], limpio[12, 4], limpio[16, 4], limpio[20, 12]].join("-")
    end

    def fecha_comparacion(valor)
      texto(valor).split.first.to_s
    end

    def fecha_iso(valor)
      limpio = fecha_comparacion(valor)
      return nil if limpio.empty?

      FORMATOS_FECHA.each do |formato|
        begin
          return Date.strptime(limpio, formato).strftime("%Y-%m-%d")
        rescue Date::Error
          next
        end
      end
      limpio
    end

    def decimal(valor)
      limpio = texto(valor)
      return nil if limpio.empty?

      BigDecimal(limpio)
    rescue ArgumentError
      limpio
    end

    def entero(valor)
      limpio = texto(valor)
      return nil if limpio.empty?

      Integer(limpio, exception: false) || limpio
    end

    def formatear_decimal(valor)
      signo = valor.negative? ? "-" : ""
      parte_entera, parte_decimal = format("%.2f", valor.abs).split(".")
      agrupada = parte_entera.reverse.scan(/\d{1,3}/).join(".").reverse
      "#{signo}#{agrupada},#{parte_decimal}"
    end
  end
end
