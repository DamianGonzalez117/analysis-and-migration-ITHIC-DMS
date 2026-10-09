# frozen_string_literal: true

require "pg"

module Ithic
  class BaseDatos
    def initialize(host:, puerto:, usuario:, contrasena:, base:, esquema: nil, timeout: 10)
      @host = host
      @puerto = puerto
      @usuario = usuario
      @contrasena = contrasena
      @base = base
      @esquema = esquema
      @timeout = timeout
    end

    def self.desde(configuracion)
      new(**configuracion.conexion_bd)
    end

    def conexion
      @conexion ||= conectar
    end

    def consultar(sql, argumentos = [])
      conexion.exec_params(sql, argumentos).map { |fila| fila.transform_keys(&:upcase) }
    end

    def ejecutar(sql, argumentos = [])
      conexion.exec_params(sql, argumentos)
    end

    def cerrar
      @conexion&.close
      @conexion = nil
    end

    private

    def conectar
      conexion = PG.connect(
        host: @host,
        port: @puerto,
        user: @usuario,
        password: @contrasena,
        dbname: @base,
        connect_timeout: @timeout
      )
      if @esquema && !@esquema.to_s.empty?
        conexion.exec("SET search_path TO #{PG::Connection.quote_ident(@esquema)}")
      end
      conexion
    rescue PG::Error => e
      raise ErrorConexion, "No se pudo conectar a PostgreSQL: #{e.message}"
    end
  end
end
