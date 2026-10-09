# frozen_string_literal: true

RSpec.describe Ithic::LectorTxt do
  around do |ejemplo|
    Dir.mktmpdir do |dir|
      @dir = dir
      ejemplo.run
    end
  end

  def escribir(nombre, contenido)
    ruta = File.join(@dir, nombre)
    File.binwrite(ruta, contenido)
    ruta
  end

  it "lee columnas separadas por | y recorta espacios" do
    ruta = escribir("pagares-26.txt", "CON_ID|COI_UUID|COI_AMOUNT\n1| abc |10.5\n2|def|\n")
    fuente = described_class.leer(ruta)
    expect(fuente.campos).to eq(%w[CON_ID COI_UUID COI_AMOUNT])
    expect(fuente.filas.first).to eq("CON_ID" => "1", "COI_UUID" => "abc", "COI_AMOUNT" => "10.5")
    expect(fuente.filas.last).to eq("CON_ID" => "2", "COI_UUID" => "def", "COI_AMOUNT" => "")
  end

  it "ignora el BOM de archivos utf-8" do
    ruta = escribir("bom.txt", "\xEF\xBB\xBFCON_ID|COI_UUID\n1|abc\n")
    fuente = described_class.leer(ruta)
    expect(fuente.campos).to eq(%w[CON_ID COI_UUID])
  end

  it "decodifica archivos latin-1" do
    ruta = escribir("latin1.txt", "CON_ID|OBS_NAME\n1|SEÑALADO\n".encode("ISO-8859-1"))
    fuente = described_class.leer(ruta)
    expect(fuente.filas.first["OBS_NAME"]).to eq("SEÑALADO")
  end

  it "falla si el archivo no existe" do
    expect { described_class.leer(File.join(@dir, "nada.txt")) }.to raise_error(Ithic::ErrorFuente)
  end
end
