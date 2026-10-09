# frozen_string_literal: true

RSpec.describe Ithic::Configuracion do
  CLAVES = %w[CONNECTION_STRING USER PASSWORD DATABASE SCHEMA].freeze

  around do |ejemplo|
    previos = ENV.to_h.slice(*CLAVES)
    CLAVES.each { |clave| ENV.delete(clave) }
    Dir.mktmpdir do |dir|
      @dir = dir
      ejemplo.run
    end
  ensure
    CLAVES.each { |clave| ENV.delete(clave) }
    previos.each { |clave, valor| ENV[clave] = valor }
  end

  it "lee la conexión desde .env" do
    File.write(File.join(@dir, ".env"), <<~ENVFILE)
      CONNECTION_STRING="host.db:5432"
      USER="demo"
      PASSWORD="secreto"
      DATABASE="postgres"
      SCHEMA="core"
    ENVFILE
    configuracion = described_class.new(raiz: @dir)
    esperado = { host: "host.db", puerto: "5432", usuario: "demo",
                 contrasena: "secreto", base: "postgres", esquema: "core" }
    expect(configuracion.conexion_bd).to eq(esperado)
  end

  it "lista los mapeos disponibles" do
    FileUtils.mkdir_p(File.join(@dir, "config", "mapeos"))
    File.write(File.join(@dir, "config", "mapeos", "pagares.yml"), "nombre: pagares\n")
    configuracion = described_class.new(raiz: @dir)
    expect(configuracion.listar_mapeos).to eq(["pagares"])
  end

  it "falla si falta CONNECTION_STRING" do
    configuracion = described_class.new(raiz: @dir)
    expect { configuracion.conexion_bd }.to raise_error(Ithic::ErrorConfiguracion)
  end
end
