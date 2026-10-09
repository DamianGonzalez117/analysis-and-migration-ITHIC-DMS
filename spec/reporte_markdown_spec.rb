# frozen_string_literal: true

RSpec.describe Ithic::ReporteMarkdown do
  around do |ejemplo|
    Dir.mktmpdir do |dir|
      @dir = dir
      ejemplo.run
    end
  end

  let(:mapeo) { Ithic::Mapeo.cargar(fixture("mapeo_prueba.yml")) }
  let(:fuente) do
    Ithic::Fuente.new(ruta: Pathname.new("pagares-26.txt"), campos: [], filas: [{}, {}])
  end
  let(:campo_monto) { Ithic::Mapeo::Campo.new(fuente: "COI_AMOUNT", dsm: "COI_AMOUNT", tipo: :decimal) }
  let(:campo_obs) { Ithic::Mapeo::Campo.new(fuente: "OBS_NAME", dsm: "OBS_NAME", tipo: :texto) }
  let(:resultado) do
    Ithic::Comparador::Resultado.new(
      total_fuente: 2, total_dsm: 2, solo_fuente: 0, solo_dsm: 0,
      campos_comparados: [campo_monto],
      campos_faltantes: [campo_obs],
      diferencias: [
        Ithic::Diferencia.new(clave: "ABC", campo: "COI_AMOUNT",
                              valor_fuente: BigDecimal("100"), valor_dsm: BigDecimal("90"),
                              descripcion: "-10,00")
      ]
    )
  end

  it "escribe el reporte por campo y el resumen" do
    reporte = described_class.new(mapeo, resultado, fuente: fuente,
                                                       parametros: { year: 2026 }, destino: @dir)
    salida = reporte.escribir!
    expect(salida.generados.map { |ruta| File.basename(ruta) }).to eq(["diferencia_COI_AMOUNT-26.md"])
    contenido = File.read(File.join(@dir, "diferencia_COI_AMOUNT-26.md"))
    expect(contenido).to include("# Diferencias pagares-26 - COI_AMOUNT")
    expect(contenido).to include("| ABC | 100,00 | 90,00 | -10,00 |")
    expect(File).to exist(File.join(@dir, "resumen-pagares-26.md"))
    expect(File.read(File.join(@dir, "resumen-pagares-26.md"))).to include("Resultado: NO CUADRA")
  end

  it "borra reportes obsoletos de campos sin diferencias" do
    obsoleto = File.join(@dir, "diferencia_COI_AMOUNT-26.md")
    File.write(obsoleto, "viejo")
    resultado_vacio = resultado.dup
    resultado_vacio.diferencias = []
    reporte = described_class.new(mapeo, resultado_vacio, fuente: fuente,
                                                             parametros: { year: 2026 }, destino: @dir)
    salida = reporte.escribir!
    expect(salida.eliminados.map { |ruta| File.basename(ruta) })
      .to include("diferencia_COI_AMOUNT-26.md")
    expect(File).not_to exist(obsoleto)
  end
end
