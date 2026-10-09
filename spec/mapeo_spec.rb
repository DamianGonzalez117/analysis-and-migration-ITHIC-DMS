# frozen_string_literal: true

RSpec.describe Ithic::Mapeo do
  subject(:mapeo) { described_class.cargar(fixture("mapeo_prueba.yml")) }

  it "extrae parámetros desde el nombre del archivo" do
    expect(mapeo.parametros_desde_archivo("pagares-26.txt")).to eq(year: 2026)
  end

  it "convierte --param year=26 sumando el siglo" do
    expect(mapeo.convertir_parametro(:year, "26")).to eq(2026)
  end

  it "reemplaza :parametros por posicionales en orden" do
    sql, valores = mapeo.sql_con_valores(year: 2026)
    expect(sql).to include("year = $1 and otra = $2")
    expect(valores).to eq([2026, 2026])
  end

  it "falla si falta un valor de la consulta" do
    expect { mapeo.sql_con_valores({}) }.to raise_error(Ithic::ErrorMapeo, /:year/)
  end

  it "falla con un parámetro desconocido" do
    expect { mapeo.convertir_parametro(:mes, "1") }.to raise_error(Ithic::ErrorMapeo, /desconocido/)
  end

  it "expone los campos declarados" do
    expect(mapeo.campos.map(&:fuente)).to eq(%w[COI_AMOUNT OBS_NAME COI_EXPIRATION_DATE])
  end

  it "expone la configuración de migración" do
    expect(mapeo.migracion.tabla).to eq("promissory_notes")
    expect(mapeo.migracion.columnas.map(&:columna)).to eq(%w[amount expiration_date])
  end
end
