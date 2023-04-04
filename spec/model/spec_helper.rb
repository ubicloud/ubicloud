# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
require_relative "../../model"
raise "test database doesn't end with test" if DB.opts[:database] && !DB.opts[:database].end_with?("test")

Sequel::Model.freeze_descendents

require_relative "../spec_helper"
