# frozen_string_literal: true

require "pathname"

module Ithic
  class Configuracion
    attr_reader :raiz

    def initialize(raiz: Ithic::RAIZ)
      @raiz = Pathname.new(File.expand_path(raiz))
      cargar_env
    end

    def mapeos_dir
      @raiz.join("config", "mapeos")
    end

    def ruta_mapeo(nombre)
      candidatos = [
        Pathname.new(nombre.to_s),
        @raiz.join(nombre.to_s),
        mapeos_dir.join("#{nombre}.yml"),
        mapeos_dir.join(nombre.to_s),
      ]
      candidatos.find(&:file?)
    end

    def listar_mapeos
      Dir.glob(mapeos_dir.join("*.yml")).sort.map { |ruta| File.basename(ruta, ".yml") }
    end

    def entrada_dir
      @raiz.join("data", "entrada")
    end

    def reportes_dir
      @raiz.join("data", "reportes")
    end

    def conexion_bd
      partes = partes_connection_string
      {
        host: partes[0],
        puerto: partes[1],
        usuario: ENV["USER"],
        contrasena: ENV["PASSWORD"],
        base: ENV["DATABASE"] || "postgres",
        esquema: ENV["SCHEMA"],
      }
    end

    private

    def partes_connection_string
      cadena = ENV["CONNECTION_STRING"].to_s
      host, separador, puerto = cadena.rpartition(":")
      if host.empty? || separador.empty? || puerto.empty?
        raise ErrorConfiguracion, "Falta CONNECTION_STRING con el formato host:puerto (revisa tu .env)"
      end
      [host, puerto]
    end

    def cargar_env
      archivos = [@raiz.join(".env"), @raiz.join("config", ".env")]
      archivo = archivos.find(&:file?)
      return unless archivo

      archivo.each_line do |linea|
        linea = linea.strip
        next if linea.empty? || linea.start_with?("#") || !linea.include?("=")

        clave, _, valor = linea.partition("=")
        ENV[clave.strip] ||= valor.strip.gsub(/\A["']|["']\z/, "")
      end
    end
  end
end
