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
          begin
            acciones = sentencias_update(base)
            puts "\nQué hacer (SQL de actualización para esta base):"
            acciones.each_with_index do |sql, indice|
              puts "\n-- #{indice + 1}"
              puts sql
            end
            puts "\nPara aplicarlo: bundle exec ruby scripts/migracion_brands_and_customerbrands/actualizar_marcas.rb --ejecutar"
            puts "Para un entorno limpio: bundle exec ruby scripts/migracion_brands_and_customerbrands/insertar_marcas.rb"
          rescue ErrorMigracion => e
            puts "\nNo se pudo construir el plan de actualización automático: #{e.message}"
            puts "Si los registros no existen, revisa insertar_marcas.rb."
          end
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
