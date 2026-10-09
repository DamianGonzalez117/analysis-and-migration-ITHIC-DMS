# frozen_string_literal: true

RSpec.describe Ithic::Migrador do
  subject(:migrador) do
    described_class.new(mapeo, fuente: fuente, claves_dsm: claves_dsm)
  end

  let(:mapeo) { Ithic::Mapeo.cargar(fixture("mapeo_prueba.yml")) }
  let(:claves_dsm) { ["aabbccdd-eeff-0011-2233-445566778899"] }
  let(:fuente) do
    Ithic::Fuente.new(
      ruta: Pathname.new("pagares-con_id252852.txt"),
      campos: %w[COI_UUID COI_AMOUNT COI_EXPIRATION_DATE],
      filas: [
        { "COI_UUID" => "AABBCCDDEEFF00112233445566778899",
          "COI_AMOUNT" => "2177119.84", "COI_EXPIRATION_DATE" => "2026/08/21" },
        { "COI_UUID" => "11112222333344445555666677778888",
          "COI_AMOUNT" => "0", "COI_EXPIRATION_DATE" => "21/08/2026" },
      ]
    )
  end

  it "separa existentes de faltantes" do
    expect(migrador.plan.total).to eq(2)
    expect(migrador.plan.total_existentes).to eq(1)
    expect(migrador.plan.total_faltantes).to eq(1)
  end

  it "genera un INSERT con ON CONFLICT DO NOTHING por faltante" do
    sentencia = migrador.sentencias.first
    expect(sentencia.sql).to include("INSERT INTO \"promissory_notes\"")
    expect(sentencia.sql).to include("ON CONFLICT (\"promissory_note_id\") DO NOTHING")
    expect(sentencia.valores[0]).to eq("11112222-3333-4444-5555-666677778888")
    expect(sentencia.valores[1]).to eq(BigDecimal("0"))
    expect(sentencia.valores[2]).to eq("2026-08-21")
  end

  it "con conflicto actualizar envía todos los registros con DO UPDATE" do
    actualizador = described_class.new(
      mapeo, fuente: fuente, claves_dsm: claves_dsm, conflicto: "actualizar"
    )
    expect(actualizador.sentencias.size).to eq(2)
    expect(actualizador.sentencias.first.sql).to include("DO UPDATE SET")
  end

  it "renderiza el SQL con literales" do
    sql = migrador.renderizar(migrador.sentencias.first)
    expect(sql).to include("'11112222-3333-4444-5555-666677778888'")
    expect(sql).to include("'2026-08-21'")
    expect(sql).to include("0")
  end

  it "falla si el archivo no trae columnas requeridas" do
    fuente_incompleta = Ithic::Fuente.new(
      ruta: Pathname.new("x.txt"),
      campos: %w[COI_UUID COI_AMOUNT],
      filas: []
    )
    expect do
      described_class.new(mapeo, fuente: fuente_incompleta, claves_dsm: [])
    end.to raise_error(Ithic::ErrorMapeo, /COI_EXPIRATION_DATE/)
  end
end
