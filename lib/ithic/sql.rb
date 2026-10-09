# frozen_string_literal: true

require "bigdecimal"
require "pg"

module Ithic
  module Sql
    module_function

    def identificador(nombre)
      partes = nombre.to_s.split(".")
      unless partes.all? { |parte| parte.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/) }
        raise ErrorMapeo, "Identificador SQL inválido: #{nombre}"
      end

      partes.map { |parte| PG::Connection.quote_ident(parte) }.join(".")
    end

    def literal(valor)
      case valor
      when nil
        "NULL"
      when BigDecimal
        valor.to_s("F")
      when Numeric
        valor.to_s
      else
        "'#{valor.to_s.gsub("'", "''")}'"
      end
    end
  end
end
