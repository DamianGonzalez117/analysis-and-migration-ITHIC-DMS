#!/usr/bin/env ruby
# frozen_string_literal: true

# Analiza los UUID existentes en DSM y genera mapa_catalogos.json:
# código externo de ITHIC -> UUID de la tabla catálogo en DSM.
#
# - Para cce/art/sales_type se resuelve por external_id del catálogo.
# - Para sales_details_types se resuelve por NAME (la columna external_id en
#   DSM está mayormente vacía) usando el catálogo del archivo.
# - Ante códigos con varias filas en DSM se elige la de mayor uso en
#   consumption_blocked_details; si hay empate, la creada primero.
#
# Uso: bundle exec ruby scripts/migracion_consumos/generar_mapa.rb

require "time"
require_relative "comun"

module MigracionConsumos
  module GeneradorMapa
    extend MigracionConsumos

    module_function

    def ejecutar
      base = conexion
      begin
        mapa = {}
        detalle = {}
        sin_match = {}
        codigos_usados = codigos_en_consumos

        # cce / art / sales_type: por external_id
        %w[cce art sales_type].each do |categoria|
          config = TABLAS_CATALOGO[categoria]
          _, filas = leer_catalogo(config[:archivo])
          codigos = filas.map { |fila| fila["EXTERNAL_ID"].to_s.strip }
          codigos |= codigos_usados[categoria]
          mapa[categoria], detalle[categoria], sin_match[categoria] =
            resolver_por_external_id(base, config[:tabla], config[:id], codigos)
        end

        mapa["sd"], detalle["sd"], sin_match["sd"] = resolver_sd(base, codigos_usados["sd"])

        salida = {
          "generado_en" => Time.now.utc.iso8601,
          "fuente" => "generar_mapa.rb",
          "catalogs" => mapa,
          "sin_match" => sin_match.transform_values { |valores| valores.map(&:to_s) },
          "detalle" => detalle
        }
        File.write(RUTA_MAPA, JSON.pretty_generate(salida), encoding: "UTF-8")

        puts "Mapa generado: #{RUTA_MAPA}"
        %w[cce art sales_type sd].each do |categoria|
          usados = codigos_usados[categoria]
          resueltos = usados.count { |codigo| mapa[categoria].key?(codigo) }
          nulos = usados.count { |codigo| codigo.empty? || codigo == "0" }
          faltan = usados.reject { |codigo| mapa[categoria].key?(codigo) || codigo.empty? || codigo == "0" }
          puts format("  %-11s codigos usados=%3d resueltos=%3d nulos=%3d sin_match=%s",
                      categoria, usados.size, resueltos, nulos, faltan.empty? ? "ninguno" : faltan.sort.join(", "))
        end
      ensure
        base.cerrar
      end
    end

    def codigos_en_consumos
      registros, _ = parsear_consumos
      {
        "cce" => registros.map { |fila| fila["EXTERNAL_CAT_CONST_CENTER_CONSUMPTION"].to_s.strip }.uniq,
        "art" => registros.map { |fila| fila["EXTERNAL_CAT_ACCOUNTING_RECORD_TYPES"].to_s.strip }.uniq,
        "sales_type" => registros.map { |fila| fila["EXTERNAL_CAT_SALES_TYPES"].to_s.strip }.uniq,
        "sd" => registros.map { |fila| fila["EXTERNAL_CAT_SALES_DETAILS_TYPE"].to_s.strip }.uniq
      }
    end

    def resolver_por_external_id(base, tabla, id_col, codigos)
      candidatos = consultar_candidatos(base, tabla, id_col)
      por_codigo = Hash.new { |hash, clave| hash[clave] = [] }
      candidatos.each do |fila|
        external = fila["EXT"].to_s.strip
        next if external.empty?

        por_codigo[external] << fila
      end

      mapa = {}
      detalle = {}
      sin_match = []
      codigos.uniq.each do |codigo|
        next if codigo.empty? || codigo == "0"

        lista = ordenar(por_codigo[codigo])
        if lista.empty?
          sin_match << codigo
          next
        end

        mapa[codigo] = lista.first["UUID"]
        detalle[codigo] = lista.first(4).map { |fila| describir(fila) }
      end
      [mapa, detalle, sin_match]
    end

    def resolver_sd(base, codigos_usados)
      config = TABLAS_CATALOGO["sd"]
      candidatos = consultar_candidatos(base, config[:tabla], config[:id])
      por_nombre = Hash.new { |hash, clave| hash[clave] = [] }
      candidatos.each do |fila|
        por_nombre[fila["NOMBRE"].to_s.strip.downcase] << fila
      end

      _, filas_archivo = leer_catalogo(config[:archivo])
      codigos_por_nombre = Hash.new { |hash, clave| hash[clave] = [] }
      filas_archivo.each do |fila|
        codigos_por_nombre[fila["NAME"].to_s.strip] << fila["EXTERNAL_ID"].to_s.strip
      end

      mapa = {}
      detalle = {}
      sin_match = []

      codigos_por_nombre.each do |nombre, codigos|
        lista = ordenar(por_nombre[nombre.downcase])
        if lista.empty?
          sin_match.concat(codigos.reject { |codigo| codigo.empty? || codigo == "0" })
          next
        end

        usables = codigos.reject { |codigo| codigo.empty? || codigo == "0" }
                       .sort_by { |codigo| codigo.to_i }
        usables.each_with_index do |codigo, indice|
          elegido = lista[indice] || lista.first
          mapa[codigo] = elegido["UUID"]
          detalle[codigo] = {
            "nombre" => nombre,
            "candidatos" => lista.first(4).map { |fila| describir(fila) }
          }
        end
      end

      usados_sin_resolver = codigos_usados.reject { |codigo| codigo.empty? || codigo == "0" || mapa.key?(codigo) }
      sin_match.concat(usados_sin_resolver)
      [mapa, detalle, sin_match.uniq]
    end

    def consultar_candidatos(base, tabla, id_col)
      sql = <<~SQL
        SELECT t.external_id::text AS ext, t.name AS nombre, t.created_at AS creado,
               t.#{id_col}::text AS uuid,
               (SELECT count(*) FROM consumption_blocked_details d
                 WHERE d.#{id_col} = t.#{id_col}) AS uso
        FROM #{tabla} t
      SQL
      base.consultar(sql)
    end

    def ordenar(filas)
      filas.sort_by { |fila| [-fila["USO"].to_i, fila["CREADO"].to_s, fila["UUID"]] }
    end

    def describir(fila)
      {
        "uuid" => fila["UUID"],
        "nombre" => fila["NOMBRE"],
        "uso_en_consumos" => fila["USO"].to_i,
        "creado" => fila["CREADO"].to_s
      }
    end
  end
end

MigracionConsumos::GeneradorMapa.ejecutar
