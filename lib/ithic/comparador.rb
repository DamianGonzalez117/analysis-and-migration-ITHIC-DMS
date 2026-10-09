# frozen_string_literal: true

require "bigdecimal"

module Ithic
  Diferencia = Struct.new(:clave, :campo, :valor_fuente, :valor_dsm, :descripcion, keyword_init: true)

  class Comparador
    Resultado = Struct.new(
      :total_fuente, :total_dsm, :solo_fuente, :solo_dsm,
      :campos_comparados, :campos_faltantes, :diferencias,
      keyword_init: true
    ) do
      def diferencias_por_campo(fuente_campo)
        diferencias.select { |diferencia| diferencia.campo == fuente_campo }
      end

      def cuadra?
        diferencias.empty? && solo_fuente.zero? && solo_dsm.zero?
      end
    end

    def initialize(mapeo, fuente, filas_dsm)
      @mapeo = mapeo
      @fuente = fuente
      @filas_dsm = filas_dsm
    end

    def comparar
      campos = @mapeo.campos.select { |campo| @fuente.campos.include?(campo.fuente) }
      faltantes = @mapeo.campos.reject { |campo| @fuente.campos.include?(campo.fuente) }

      registros_fuente = indexar(@fuente.filas, @mapeo.clave.fuente)
      registros_dsm = indexar(@filas_dsm, @mapeo.clave.dsm)

      diferencias = []
      solo_fuente = 0

      registros_fuente.each do |clave, fila_fuente|
        fila_dsm = registros_dsm[clave]
        if fila_dsm.nil?
          solo_fuente += 1
          campos.each do |campo|
            diferencias << Diferencia.new(
              clave: clave, campo: campo.fuente,
              valor_fuente: normalizar(campo.tipo, fila_fuente[campo.fuente]),
              valor_dsm: nil,
              descripcion: "solo en ITHIC"
            )
          end
          next
        end

        campos.each do |campo|
          valor_fuente = normalizar(campo.tipo, fila_fuente[campo.fuente])
          valor_dsm = normalizar(campo.tipo, fila_dsm[campo.dsm])
          next if valor_fuente == valor_dsm

          diferencias << Diferencia.new(
            clave: clave, campo: campo.fuente,
            valor_fuente: valor_fuente, valor_dsm: valor_dsm,
            descripcion: describir(campo, valor_fuente, valor_dsm)
          )
        end
      end

      solo_dsm = 0
      registros_dsm.each do |clave, fila_dsm|
        next if registros_fuente.key?(clave)

        solo_dsm += 1
        campos.each do |campo|
          diferencias << Diferencia.new(
            clave: clave, campo: campo.fuente,
            valor_fuente: nil,
            valor_dsm: normalizar(campo.tipo, fila_dsm[campo.dsm]),
            descripcion: "solo en DSM"
          )
        end
      end

      Resultado.new(
        total_fuente: @fuente.filas.size,
        total_dsm: @filas_dsm.size,
        solo_fuente: solo_fuente,
        solo_dsm: solo_dsm,
        campos_comparados: campos,
        campos_faltantes: faltantes,
        diferencias: diferencias
      )
    end

    private

    def indexar(filas, campo_clave)
      filas.each_with_object({}) do |fila, registros|
        registros[normalizar(@mapeo.clave.tipo, fila[campo_clave])] = fila
      end
    end

    def normalizar(tipo, valor)
      Normalizador.normalizar(tipo, valor)
    end

    def describir(campo, valor_fuente, valor_dsm)
      return "sin dato en ITHIC" if valor_fuente.nil? || valor_fuente == ""
      return "sin dato en DSM" if valor_dsm.nil? || valor_dsm == ""
      if campo.tipo == :decimal && valor_fuente.is_a?(BigDecimal) && valor_dsm.is_a?(BigDecimal)
        return Normalizador.formatear_decimal(valor_dsm - valor_fuente)
      end

      "distinto"
    end
  end
end
