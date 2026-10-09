# frozen_string_literal: true

module Ithic
  RAIZ = File.expand_path("..", __dir__).freeze
end

require_relative "ithic/version"
require_relative "ithic/errores"
require_relative "ithic/sql"
require_relative "ithic/configuracion"
require_relative "ithic/base_datos"
require_relative "ithic/repositorio_dsm"
require_relative "ithic/lector_txt"
require_relative "ithic/normalizador"
require_relative "ithic/mapeo"
require_relative "ithic/comparador"
require_relative "ithic/reporte_markdown"
require_relative "ithic/migrador"
require_relative "ithic/cli"
