# frozen_string_literal: true

require "bigdecimal"
require "fileutils"
require "pathname"

module Ithic
  class ReporteMarkdown
    Salida = Struct.new(:generados, :resumen, :eliminados, keyword_init: true)

    def initialize(mapeo, resultado, fuente:, parametros: {}, destino:)
      @mapeo = mapeo
      @resultado = resultado
      @fuente = fuente
      @parametros = parametros
      @destino = Pathname.new(destino)
      @sufijo = calcular_sufijo
    end

    def etiqueta
      @etiqueta ||= [@mapeo.nombre, @sufijo].compact.join("-")
    end

    def ruta_campo(campo)
      @destino.join("diferencia_#{campo.fuente}#{@sufijo ? "-#{@sufijo}" : ""}.md")
    end

    def nombre_resumen
      "resumen-#{etiqueta}.md"
    end

    def escribir!
      FileUtils.mkdir_p(@destino)
      generados = []
      eliminados = []

      @resultado.campos_comparados.each do |campo|
        filas = @resultado.diferencias_por_campo(campo.fuente)
        ruta = ruta_campo(campo)
        if filas.empty?
          eliminados << borrar(ruta)
        else
          ruta.write(contenido_campo(campo, filas))
          generados << ruta
        end
      end

      @resultado.campos_faltantes.each do |campo|
        eliminados << borrar(ruta_campo(campo))
      end

      resumen = @destino.join(nombre_resumen)
      resumen.write(contenido_resumen)

      Salida.new(generados: generados, resumen: resumen, eliminados: eliminados.compact)
    end

    private

    def calcular_sufijo
      return nil if @parametros.empty?

      nombre = @mapeo.reporte_sufijo || (@parametros.key?(:year) ? "year" : nil)
      return nil unless nombre

      valor = @parametros[nombre.to_sym]
      return nil if valor.nil?

      valor.is_a?(Integer) ? format("%02d", valor % 100) : valor.to_s
    end

    def borrar(ruta)
      return nil unless ruta.file?

      ruta.unlink
      ruta
    end

    def contenido_campo(campo, filas)
      lineas = [
        "# Diferencias #{etiqueta} - #{campo.fuente}",
        "",
        "- Archivo ITHIC: `#{@fuente.ruta.basename}` con #{@resultado.total_fuente} registros",
        "- Registros DSM#{sufijo_dsm}: #{@resultado.total_dsm}",
        "- Registros solo en ITHIC: #{@resultado.solo_fuente}",
        "- Registros solo en DSM: #{@resultado.solo_dsm}",
        "- Filas con diferencia en #{campo.fuente}: #{filas.size}",
        "",
        "En montos, la diferencia es DSM - ITHIC.",
        "",
        "| #{@mapeo.clave.fuente} | ITHIC | DSM | Diferencia |",
        "| --- | --- | --- | --- |",
      ]
      filas.each do |diferencia|
        lineas << "| #{celda(diferencia.clave)} | #{celda(formatear(campo, diferencia.valor_fuente))} | " \
                  "#{celda(formatear(campo, diferencia.valor_dsm))} | #{celda(diferencia.descripcion)} |"
      end
      lineas << ""
      lineas.join("\n")
    end

    def contenido_resumen
      lineas = [
        "# Resumen #{etiqueta}",
        "",
        "- Archivo ITHIC: `#{@fuente.ruta.basename}` con #{@resultado.total_fuente} registros",
        "- Registros DSM#{sufijo_dsm}: #{@resultado.total_dsm}",
        "- Registros solo en ITHIC: #{@resultado.solo_fuente}",
        "- Registros solo en DSM: #{@resultado.solo_dsm}",
        "- Resultado: #{@resultado.cuadra? ? 'CUADRA' : 'NO CUADRA'}",
        "",
      ]

      if @resultado.diferencias.empty?
        lineas << "Sin diferencias."
      else
        lineas << "Diferencias por campo:"
        @resultado.campos_comparados.each do |campo|
          lineas << "- #{campo.fuente}: #{@resultado.diferencias_por_campo(campo.fuente).size}"
        end
      end

      unless @resultado.campos_faltantes.empty?
        lineas << ""
        lineas << "Campos declarados ausentes en ITHIC: " \
                  "#{@resultado.campos_faltantes.map(&:fuente).join(', ')}"
      end

      lineas << ""
      lineas.join("\n")
    end

    def sufijo_dsm
      @parametros[:year] ? " (#{@parametros[:year]})" : ""
    end

    def formatear(campo, valor)
      return "(vacío)" if valor.nil? || valor == ""
      return Normalizador.formatear_decimal(valor) if campo.tipo == :decimal && valor.is_a?(BigDecimal)

      valor.to_s
    end

    def celda(valor)
      valor.to_s.gsub("|", "\\|").gsub(/\r?\n/, " ")
    end
  end
end
