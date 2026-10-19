#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "comun"

module MigracionMarcas
  module Actualizador
    extend MigracionMarcas

    module_function

    def ejecutar(argv)
      opciones = parsear_opciones(argv, "actualizar_marcas.rb")
      cargar_env!
      describir_conexion
      base = nil
      begin
        base = conexion
        comparacion = comparar(marcas, dsm(base))
        imprimir_comparacion(comparacion)
        if comparacion[:faltan].empty?
          puts "\nNo hay external_id faltantes. Nada por actualizar."
          return 0
        end

        sentencias = sentencias_update(base)
        imprimir_sentencias(sentencias)
        escribir_sql(opciones[:sql], sentencias) if opciones[:sql]

        if opciones[:ejecutar]
          aplicar(base, sentencias)
          puts "\nActualización aplicada."
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

exit(MigracionMarcas::Actualizador.ejecutar(ARGV))
