# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "ithic"
require "tmpdir"

module Ayudas
  def fixture(nombre)
    File.expand_path("fixtures/#{nombre}", __dir__)
  end
end

RSpec.configure do |config|
  config.include Ayudas
  config.order = :random
  config.expect_with(:rspec) { |expectativas| expectativas.syntax = :expect }
end
