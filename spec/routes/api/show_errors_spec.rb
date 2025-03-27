# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover do
  before do
    unless (@show_errors = ENV["SHOW_ERRORS"])
      ENV["SHOW_ERRORS"] = "1"
    end
    @account = create_account
    login_api
  end

  after do
    ENV.delete("SHOW_ERRORS") unless @show_errors
  end

  it "supports SHOW_ERRORS environment variable when testing" do
    project_with_default_policy(@account, name: "project-1")
    expect { post "/project", {}.to_json }.to raise_error Committee::InvalidRequest
  end
end
