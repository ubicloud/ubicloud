# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  config.include(Module.new do
    def login_api
      @use_pat = true
    end

    def project_with_default_policy(account, name: "project-1")
      project = account.create_project_with_default_policy(name)

      if @use_pat
        @pat = account.api_keys.first || ApiKey.create_personal_access_token(account, project:)
        header "Authorization", "Bearer pat-#{@pat.ubid}-#{@pat.key}"
        SubjectTag.first(project_id: project.id, name: "Admin").add_subject(@pat.id)
      end

      project
    end
  end)

  config.define_derived_metadata(file_path: %r{\A\./spec/routes/api/}) do |metadata|
    metadata[:clover_api] = true
  end

  config.before do |example|
    next unless example.metadata[:clover_api]
    header "Host", "api.ubicloud.com"
    header "Content-Type", "application/json"
    header "Accept", "application/json"
  end
end
