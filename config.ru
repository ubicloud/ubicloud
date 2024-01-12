# frozen_string_literal: true

require_relative "loader"

run(Config.development? ? Unreloader : Clover.freeze.app)
