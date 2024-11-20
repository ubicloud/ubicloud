# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  before do
    unless (@show_errors = ENV["SHOW_ERRORS"])
      ENV["SHOW_ERRORS"] = "1"
    end
    login_api(create_account.email)
  end

  after do
    ENV.delete("SHOW_ERRORS") unless @show_errors
  end

  it "supports SHOW_ERRORS environment variable when testing" do
    expect { post "/project", {}.to_json }.to raise_error Validation::ValidationFailed
  end
end
