# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  def cli(argv, status: 200, env: {}, confirm_prompt: nil)
    post("/cli", {"argv" => argv}.to_json, env)
    expect(last_response.status).to eq(status), "status is #{last_response.status} not #{status}, body for failing status: #{last_response.body}"
    expect(last_response["content-type"]).to eq("text/plain")
    expect(last_response["ubi-confirm"]).to eq(confirm_prompt) if confirm_prompt
    last_response.body
  end

  def cli_exec(argv, env: {})
    body = cli(argv, env:)
    [last_response.headers["ubi-command-execute"], *body.split("\0")]
  end

  config.define_derived_metadata(file_path: %r{\A\./spec/routes/api/cli/}) do |metadata|
    metadata[:clover_cli] = true
  end

  config.before do |example|
    next unless example.metadata[:clover_cli]
    header "Accept", "text/plain"
    @account = create_account
    @use_pat = true
    @project = project_with_default_policy(@account, name: "project-1")
  end
end
