# frozen_string_literal: true

module Ithic
  class ErrorIthic < StandardError; end

  class ErrorConfiguracion < ErrorIthic; end

  class ErrorConexion < ErrorIthic; end

  class ErrorFuente < ErrorIthic; end

  class ErrorMapeo < ErrorIthic; end
end
