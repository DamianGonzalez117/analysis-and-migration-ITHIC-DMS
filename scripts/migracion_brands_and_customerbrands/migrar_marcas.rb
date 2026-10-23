#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "comun"

module MigracionMarcas
  module MigradorMarcas
    extend MigracionMarcas

    module_function

    def ejecutar(argv)
      opciones = parsear_opciones(argv, "migrar_marcas.rb")
      sentencias = sentencias_migracion_directa
      if sentencias.empty?
        puts "No hay registros en #{RUTA_CUSTOMER_BRANDS} ni #{RUTA_SUB_BRANDS}."
        return 0
      end

      puts "Archivos: #{RUTA_CUSTOMER_BRANDS} / #{RUTA_SUB_BRANDS}"
      puts "Registros: #{pares_fuente.size} (customer_brands + sub_brands)"
      puts "Sentencias: #{sentencias.size}"
      puts "updated_by: #{usuario_migracion}"

      escribir_sql(opciones[:sql], sentencias) if opciones[:sql]

      if opciones[:ejecutar]
        cargar_env!
        describir_conexion
        base = conexion
        begin
          aplicar(base, sentencias)
          puts "\nInserción aplicada."
        ensure
          base.cerrar
        end
      else
        puts "\nNo se ejecutó nada en la base. Usa --ejecutar para aplicar."
      end
      0
    rescue Ithic::ErrorIthic, PG::Error, ErrorMigracion => e
      warn "\nERROR: #{e.message}"
      1
    end
  end
end

exit(MigracionMarcas::MigradorMarcas.ejecutar(ARGV))
