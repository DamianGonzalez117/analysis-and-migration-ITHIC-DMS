#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "comun"

module MigracionMarcas
  module Insertador
    extend MigracionMarcas

    module_function

    def ejecutar(argv)
      opciones = parsear_opciones(argv, "insertar_marcas.rb")
      cargar_env!
      describir_conexion
      base = nil
      begin
        base = conexion
        comparacion = comparar(marcas, dsm(base))
        imprimir_comparacion(comparacion)
        if comparacion[:faltan].empty?
          puts "\nNo hay external_id faltantes. Nada por insertar."
          return 0
        end

        pares, existentes = seleccionar_para_insert(base, comparacion[:faltan])
        if pares.empty?
          puts "\nLos external_id faltantes no están en los archivos de entrada. Nada por insertar."
          return 0
        end

        unless existentes.empty?
          detalle = existentes.map { |externo, fila| "#{externo} (actual #{fila['EXTERNAL_ID']})" }.join(", ")
          if opciones[:ejecutar]
            raise ErrorMigracion,
                  "Los sub_brand_id ya existen en core.sub_brands: #{detalle}. Usa actualizar_marcas.rb."
          end
          puts "\nAviso: estos sub_brand_id ya existen en la base: #{detalle}."
          puts "El plan de INSERT se muestra solo como referencia para un entorno limpio."
        end

        marca_id = marca_insert(base)
        if marca_id.nil?
          raise ErrorMigracion, "No existe en core.brands ni #{MARCA_SIN_MARCA} ni #{MARCA_ALTERNA}"
        end

        if pares.any? { |par| par[:customer_brand]["BRAND_ID"].downcase != marca_id }
          puts "\nAviso: customer_brands.txt usa otro brand_id; se usará #{marca_id}."
        end
        if pares.any? { |par| par[:sub]["BRAND_ID"].downcase != marca_id }
          puts "Aviso: sub_brands.txt usa otro brand_id; se usará #{marca_id}."
        end
        pares.select { |par| uuid(par[:customer_brand]["SUBSIDIARY_ID"]) != SUBSIDIARIA_NACIONAL }.each do |par|
          puts "Aviso: #{par[:sub]['EXTERNAL_ID']} se inserta con la subsidiaria del archivo; " \
               "la consulta lo incluirá por el shared_customer de NACIONAL."
        end

        sentencias = sentencias_insert(base, pares)
        imprimir_sentencias(sentencias)
        escribir_sql(opciones[:sql], sentencias) if opciones[:sql]

        if opciones[:ejecutar]
          aplicar(base, sentencias)
          puts "\nInserción aplicada."
          ok = verificar(base)
          puts(ok ? "\nCUADRA: los datos coinciden." : "\nNO CUADRA: revisar el resultado.")
          ok ? 0 : 1
        else
          puts "\nSimulación: no se ejecutó nada. Usa --ejecutar para aplicar."
          0
        end
      rescue Ithic::ErrorIthic, PG::Error, ErrorMigracion => e
        warn "\nERROR: #{e.message}"
        warn "Si usas --ejecutar, el usuario de .env debe tener permisos de escritura."
        1
      ensure
        base&.cerrar
      end
    end
  end
end

exit(MigracionMarcas::Insertador.ejecutar(ARGV))
