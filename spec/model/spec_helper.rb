# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
require_relative "../../model"
raise "test database doesn't end with test" if DB.opts[:database] && !/test\d*\z/.match?(DB.opts[:database])

require_relative "../spec_helper"

ENV["HETZNER_CONNECTION_STRING"] = "https://robot-ws.your-server.de"
ENV["HETZNER_USER"] = "user1"
ENV["HETZNER_PASSWORD"] = "pass"
