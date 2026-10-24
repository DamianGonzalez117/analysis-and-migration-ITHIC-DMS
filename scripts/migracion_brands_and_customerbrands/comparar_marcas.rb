#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "comun"

module MigracionMarcas
  module Comparador
    extend MigracionMarcas

    module_function

    def ejecutar(argv)
      parser = OptionParser.new do |opts|
        opts.banner = "Uso: bundle exec ruby scripts/migracion_brands_and_customerbrands/comparar_marcas.rb"
        opts.on("-h", "--help", "Muestra esta ayuda") do
          puts opts
          exit(0)
        end
      end
      parser.parse!(argv)

      cargar_env!
      describir_conexion
      base = nil
      begin
        base = conexion
        registros_marcas = marcas
        registros_dsm = dsm(base)
        comparacion = comparar(registros_marcas, registros_dsm)
        detalle = detalle_faltantes(base, registros_marcas, comparacion[:faltan])

        imprimir_comparacion(comparacion)
        imprimir_detalle_faltantes(detalle)
        if shared_nacional(base, CLIENTE_POSADAS).nil?
          puts "\nAviso: el cliente #{CLIENTE_POSADAS} no tiene shared_customer en NACIONAL."
          puts "Por eso los 5 sub_brands de Posadas no aparecerán en subsidiary_number = 0."
        end

        unless comparacion[:faltan].empty?
          puts "\nSiguiente paso:"
          sin_archivo = detalle.reject { |d| d[:en_archivos] }.map { |d| d[:external_id] }
          if sin_archivo.empty?
            puts "  1. Los faltantes ya están en customer_brands.txt y sub_brands.txt."
          else
            puts "  1. Agrega a customer_brands.txt y sub_brands.txt: #{sin_archivo.join(', ')}"
          end
          puts "  2. Genera los scripts para cuadrar marcas con:"
          puts "     bundle exec ruby scripts/migracion_brands_and_customerbrands/cuadrar_marcas.rb"
        end

        ruta = escribir_reporte_comparacion(base, comparacion, detalle)
        puts "\nReporte: #{ruta}"
        cuadra = comparacion[:faltan].empty? && comparacion[:sobran].empty? && comparacion[:duplicados_dsm].empty?
        puts(cuadra ? "Resultado: CUADRA" : "Resultado: NO CUADRA")
        cuadra ? 0 : 2
      rescue Ithic::ErrorIthic, PG::Error, ErrorMigracion => e
        warn "\nERROR: #{e.message}"
        1
      ensure
        base&.cerrar
      end
    end
  end
end

exit(MigracionMarcas::Comparador.ejecutar(ARGV))
