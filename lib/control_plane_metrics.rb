# frozen_string_literal: true

require "prometheus/client"
require "prometheus/client/formats/text"

module ControlPlaneMetrics
  attr_reader :registry

  def initialize
    @registry = Prometheus::Client::Registry.new
  end

  def render
    Prometheus::Client::Formats::Text.marshal(@registry)
  end

  extend self

  initialize
end
