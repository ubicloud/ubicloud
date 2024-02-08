# frozen_string_literal: true

require_relative "loader"

clover_freeze

run(Config.development? ? Unreloader : Clover.freeze.app)

Tilt.finalize! unless Config.development?
