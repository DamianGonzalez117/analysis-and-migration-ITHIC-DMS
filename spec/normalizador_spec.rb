# frozen_string_literal: true

RSpec.describe Ithic::Normalizador do
  describe ".normalizar" do
    it "normaliza uuid a mayúsculas sin espacios" do
      expect(described_class.normalizar(:uuid, " abc123 ")).to eq("ABC123")
    end

    it "compara fechas solo por el día" do
      expect(described_class.normalizar(:fecha, "20/07/2026 00:00:00")).to eq("20/07/2026")
    end

    it "convierte montos a BigDecimal" do
      expect(described_class.normalizar(:decimal, "17300000.50")).to eq(BigDecimal("17300000.50"))
    end

    it "devuelve nil para montos vacíos" do
      expect(described_class.normalizar(:decimal, " ")).to be_nil
    end

    it "conserva el texto original si el monto es inválido" do
      expect(described_class.normalizar(:decimal, "N/A")).to eq("N/A")
    end
  end

  describe ".uuid_postgres" do
    it "agrega guiones al uuid de 32 caracteres" do
      expect(described_class.uuid_postgres("52E3E726E2F519F1E063951B400A64F6"))
        .to eq("52e3e726-e2f5-19f1-e063-951b400a64f6")
    end

    it "deja pasar uuids que ya tienen guiones" do
      expect(described_class.uuid_postgres("52e3e726-e2f5-19f1-e063-951b400a64f6"))
        .to eq("52e3e726-e2f5-19f1-e063-951b400a64f6")
    end
  end

  describe ".fecha_iso" do
    it "convierte d/m/Y a ISO" do
      expect(described_class.fecha_iso("21/08/2026")).to eq("2026-08-21")
    end

    it "convierte Y/m/d a ISO" do
      expect(described_class.fecha_iso("2026/05/28")).to eq("2026-05-28")
    end

    it "devuelve nil para vacío" do
      expect(described_class.fecha_iso("")).to be_nil
    end
  end

  describe ".formatear_decimal" do
    it "usa separadores de miles y coma decimal" do
      expect(described_class.formatear_decimal(BigDecimal("17300000"))).to eq("17.300.000,00")
    end

    it "conserva el signo" do
      expect(described_class.formatear_decimal(BigDecimal("-10"))).to eq("-10,00")
    end
  end
end
