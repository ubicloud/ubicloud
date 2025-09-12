# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  config.include(Module.new do
    def cli(argv, status: 200, env: {"HTTP_X_UBI_VERSION" => "1.0.0"}, confirm_prompt: nil, command_execute: nil)
      post("/cli", {"argv" => argv}.to_json, env)
      expect(last_response.status).to eq(status), "status is #{last_response.status} not #{status}, body for failing status: #{last_response.body}"
      if status == 400
        expect(last_response.body).to start_with("! ")
      end
      expect(last_response["content-type"]).to eq("text/plain")
      expect(last_response["ubi-command-execute"]).to eq(command_execute) if command_execute
      expect(last_response["ubi-confirm"]).to eq(confirm_prompt) if confirm_prompt
      if !last_response["ubi-command-execute"] && !last_response["ubi-confirm"]
        expect(last_response.body).to end_with("\n")
      end
      last_response.body
    end

    def cli_exec(argv, env: {}, command_pgpassword: nil)
      body = cli(argv, env:)

      if command_pgpassword
        expect(last_response["ubi-pgpassword"]).to eq(command_pgpassword)
      else
        expect(last_response["ubi-pgpassword"]).to be_nil
      end

      [last_response.headers["ubi-command-execute"], *body.split("\0")]
    end
  end)

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
