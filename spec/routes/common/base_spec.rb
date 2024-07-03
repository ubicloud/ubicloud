# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "base" do
  it "raises exception for unexpected class" do
    expect { Routes::Common::Base.new(app: Object.new, request: nil, user: nil, location: nil, resource: nil) }.to raise_error("Unknown app mode")
  end
end
