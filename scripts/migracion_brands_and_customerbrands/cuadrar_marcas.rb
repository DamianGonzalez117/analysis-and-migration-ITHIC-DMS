#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "comun"

module MigracionMarcas
  module Cuadrador
    extend MigracionMarcas

    module_function

    def ejecutar(argv)
      opciones = parsear_opciones(argv, "cuadrar_marcas.rb", accion: "Marcas y SubMarcas")
      cargar_env!
      describir_conexion
      base = nil
      begin
        base = conexion
        pares = pares_fuente
        if pares.empty?
          puts "No hay registros en #{RUTA_CUSTOMER_BRANDS} ni #{RUTA_SUB_BRANDS}."
          return 0
        end

        marca_id = marca_insert(base)
        if marca_id.nil?
          raise ErrorMigracion, "No existe en core.brands ni #{MARCA_SIN_MARCA} ni #{MARCA_ALTERNA}"
        end

        avisar_brand_id(pares, marca_id)
        resumen = resumen_cuadre(base, pares, marca_id)
        imprimir_resumen(pares, resumen)

        sentencias = sentencias_cuadre(base)
        puts "Sentencias: #{sentencias.size}"
        puts "updated_by: #{usuario_migracion}"

        escribir_sql(opciones[:sql], sentencias) if opciones[:sql]

        if opciones[:ejecutar]
          aplicar(base, sentencias)
          puts "\nCuadre aplicado."
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

    def avisar_brand_id(pares, marca_id)
      customer_brands = pares.map { |par| uuid(par[:customer_brand]["BRAND_ID"]) }.uniq - [marca_id]
      unless customer_brands.empty?
        puts "Aviso: customer_brands.txt usa brand_id #{customer_brands.join(', ')}; se usará #{marca_id}."
      end

      sub_brands = pares.map { |par| uuid(par[:sub]["BRAND_ID"]) }.uniq - [marca_id]
      return if sub_brands.empty?

      puts "Aviso: sub_brands.txt usa brand_id #{sub_brands.join(', ')}; se usará #{marca_id}."
    end

    def imprimir_resumen(pares, resumen)
      puts "Archivos: #{RUTA_CUSTOMER_BRANDS} / #{RUTA_SUB_BRANDS}"
      puts "Registros: #{pares.size} pares (customer_brands + sub_brands)"
      puts "shared_customers nuevos: #{resumen[:shared_nuevos]}"
      puts "customer_brands: #{resumen[:customer_brands_nuevos]} nuevos, " \
           "#{resumen[:customer_brands_existentes]} existentes"
      puts "sub_brands: #{resumen[:sub_brands_nuevos]} nuevos, #{resumen[:sub_brands_existentes]} existentes"
    end
  end
end

exit(MigracionMarcas::Cuadrador.ejecutar(ARGV))
