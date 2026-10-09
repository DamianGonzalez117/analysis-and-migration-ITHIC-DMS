# frozen_string_literal: true

RSpec.describe Ithic::Comparador do
  subject(:resultado) { described_class.new(mapeo, fuente, filas_dsm).comparar }

  let(:mapeo) { Ithic::Mapeo.cargar(fixture("mapeo_prueba.yml")) }
  let(:fuente) do
    Ithic::Fuente.new(
      ruta: Pathname.new("pagares-26.txt"),
      campos: %w[COI_UUID COI_AMOUNT OBS_NAME],
      filas: [
        { "COI_UUID" => "aaa", "COI_AMOUNT" => "100.50", "OBS_NAME" => "PENDIENTE" },
        { "COI_UUID" => "bbb", "COI_AMOUNT" => "5", "OBS_NAME" => "SALDADO" },
      ]
    )
  end
  let(:filas_dsm) do
    [
      { "COI_UUID" => "AAA", "COI_AMOUNT" => "90.50", "OBS_NAME" => "PENDIENTE" },
      { "COI_UUID" => "ccc", "COI_AMOUNT" => "1", "OBS_NAME" => "PENDIENTE" },
    ]
  end

  it "cuenta registros por lado" do
    expect(resultado.total_fuente).to eq(2)
    expect(resultado.total_dsm).to eq(2)
    expect(resultado.solo_fuente).to eq(1)
    expect(resultado.solo_dsm).to eq(1)
  end

  it "omite los campos declarados que no vienen en el txt" do
    expect(resultado.campos_comparados.map(&:fuente)).to eq(%w[COI_AMOUNT OBS_NAME])
    expect(resultado.campos_faltantes.map(&:fuente)).to eq(%w[COI_EXPIRATION_DATE])
  end

  it "calcula la diferencia de montos como DSM - ITHIC" do
    diferencia = resultado.diferencias_por_campo("COI_AMOUNT").find { |fila| fila.clave == "AAA" }
    expect(diferencia.valor_fuente).to eq(BigDecimal("100.50"))
    expect(diferencia.valor_dsm).to eq(BigDecimal("90.50"))
    expect(diferencia.descripcion).to eq("-10,00")
  end

  it "marca registros que solo existen de un lado" do
    expect(resultado.diferencias_por_campo("OBS_NAME").map(&:descripcion))
      .to contain_exactly("solo en ITHIC", "solo en DSM")
  end

  it "no reporta diferencias cuando todo coincide" do
    fuente_igual = Ithic::Fuente.new(
      ruta: Pathname.new("pagares-26.txt"),
      campos: %w[COI_UUID COI_AMOUNT OBS_NAME],
      filas: [{ "COI_UUID" => "aaa", "COI_AMOUNT" => "90.50", "OBS_NAME" => "PENDIENTE" }]
    )
    dsm_igual = [{ "COI_UUID" => "AAA", "COI_AMOUNT" => "90.5", "OBS_NAME" => "PENDIENTE" }]
    expect(described_class.new(mapeo, fuente_igual, dsm_igual).comparar.cuadra?).to be(true)
  end
end
