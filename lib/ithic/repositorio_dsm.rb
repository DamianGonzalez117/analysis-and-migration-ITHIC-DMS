# frozen_string_literal: true

require "set"

module Ithic
  class RepositorioDsm
    TAMANO_LOTE = 1000

    def initialize(base_datos)
      @base_datos = base_datos
    end

    def claves_existentes(tabla:, columna:, claves:)
      existentes = Set.new
      lista = claves.map(&:to_s).reject(&:empty?).uniq
      lista.each_slice(TAMANO_LOTE) do |lote|
        placeholders = (1..lote.size).map { |indice| "$#{indice}" }.join(", ")
        identificador = Sql.identificador(columna)
        sql = "SELECT #{identificador}::text AS clave FROM #{Sql.identificador(tabla)} " \
              "WHERE #{identificador} IN (#{placeholders})"
        @base_datos.consultar(sql, lote).each { |fila| existentes << fila["CLAVE"] }
      end
      existentes
    end

    def ejecutar_sentencias(sentencias)
      @base_datos.conexion.transaction do
        sentencias.each { |sentencia| @base_datos.ejecutar(sentencia.sql, sentencia.valores) }
      end
    end
  end
end
