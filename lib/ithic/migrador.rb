# frozen_string_literal: true

require "set"

module Ithic
  class Migrador
    Sentencia = Struct.new(:sql, :valores, keyword_init: true)
    Plan = Struct.new(
      :tabla, :clave_columna, :claves_fuente, :existentes, :faltantes,
      :filas_faltantes, :filas_todas, :conflicto,
      keyword_init: true
    ) do
      def total
        claves_fuente.size
      end

      def total_existentes
        existentes.size
      end

      def total_faltantes
        faltantes.size
      end
    end

    CONFLICTOS_VALIDOS = %w[nada actualizar].freeze

    attr_reader :mapeo, :fuente

    def initialize(mapeo, fuente:, repositorio: nil, claves_dsm: nil, conflicto: nil)
      @mapeo = mapeo
      @fuente = fuente
      @migracion = mapeo.migracion
      raise ErrorMapeo, "El mapeo #{mapeo.nombre} no define una sección migracion" unless @migracion

      @repositorio = repositorio
      @claves_dsm = claves_dsm && Set.new(claves_dsm.map(&:to_s))
      @conflicto = (conflicto || @migracion.conflicto || "nada").to_s
      validar!
    end

    def plan
      @plan ||= construir_plan
    end

    def sentencias
      filas = @conflicto == "actualizar" ? plan.filas_todas : plan.filas_faltantes
      filas.map { |clave, fila| construir_sentencia(clave, fila) }
    end

    def script_sql
      encabezado = [
        "-- Migración #{@mapeo.nombre} -> #{@migracion.tabla}",
        "-- Archivo fuente: #{@fuente.ruta}",
        "-- Conflicto: #{@conflicto}",
        "-- Sentencias: #{sentencias.size}",
        "",
      ]
      (encabezado + sentencias.map { |sentencia| "#{renderizar(sentencia)};" }).join("\n") + "\n"
    end

    def renderizar(sentencia)
      sentencia.sql.gsub(/\$(\d+)/) do
        Sql.literal(sentencia.valores[Regexp.last_match(1).to_i - 1])
      end
    end

    def claves_fuente
      plan.claves_fuente
    end

    private

    def validar!
      unless CONFLICTOS_VALIDOS.include?(@conflicto)
        raise ErrorMapeo, "Conflicto inválido: #{@conflicto} (usa #{CONFLICTOS_VALIDOS.join(' o ')})"
      end

      requeridas = [@migracion.clave.fuente] + @migracion.columnas_requeridas
      ausentes = requeridas.uniq - @fuente.campos
      return if ausentes.empty?

      raise ErrorMapeo,
            "El archivo #{@fuente.ruta.basename} no contiene las columnas requeridas: #{ausentes.join(', ')}"
    end

    def construir_plan
      claves_dsm = @claves_dsm || consultar_claves_dsm
      registros = {}
      @fuente.filas.each do |fila|
        clave = Normalizador.normalizar(@migracion.clave.tipo, fila[@migracion.clave.fuente])
        next if clave.nil? || clave.to_s.empty?

        registros[clave.to_s] = fila
      end

      existentes = registros.keys.select { |clave| claves_dsm.include?(clave) }
      faltantes = registros.keys - existentes
      Plan.new(
        tabla: @migracion.tabla,
        clave_columna: @migracion.clave.columna,
        claves_fuente: registros.keys,
        existentes: existentes,
        faltantes: faltantes,
        filas_faltantes: faltantes.map { |clave| [clave, registros[clave]] },
        filas_todas: registros.map { |clave, fila| [clave, fila] },
        conflicto: @conflicto
      )
    end

    def consultar_claves_dsm
      raise ErrorMapeo, "Se requiere un repositorio para consultar las claves en DSM" unless @repositorio

      @repositorio.claves_existentes(
        tabla: @migracion.tabla,
        columna: @migracion.clave.columna,
        claves: claves_crudas
      )
    end

    def claves_crudas
      @fuente.filas.map do |fila|
        Normalizador.normalizar(@migracion.clave.tipo, fila[@migracion.clave.fuente])
      end.reject { |clave| clave.nil? || clave.to_s.empty? }.uniq
    end

    def construir_sentencia(clave, fila)
      columnas = [@migracion.clave.columna] + @migracion.columnas.map(&:columna)
      valores = [clave] + @migracion.columnas.map do |columna|
        Normalizador.normalizar(columna.tipo, fila[columna.fuente])
      end
      placeholders = (1..columnas.size).map { |indice| "$#{indice}" }.join(", ")
      sql = +"INSERT INTO #{Sql.identificador(@migracion.tabla)} " \
            "(#{columnas.map { |columna| Sql.identificador(columna) }.join(', ')}) " \
            "VALUES (#{placeholders})"
      sql << conflicto_sql(columnas)
      Sentencia.new(sql: sql, valores: valores)
    end

    def conflicto_sql(columnas)
      clave = Sql.identificador(@migracion.clave.columna)
      return " ON CONFLICT (#{clave}) DO NOTHING" unless @conflicto == "actualizar"

      asignaciones = columnas[1..].map do |columna|
        identificador = Sql.identificador(columna)
        "#{identificador} = EXCLUDED.#{identificador}"
      end
      " ON CONFLICT (#{clave}) DO UPDATE SET #{asignaciones.join(', ')}"
    end
  end
end
