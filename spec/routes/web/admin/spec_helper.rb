# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{\A\./spec/routes/web/admin/}) do |metadata|
    metadata[:clover_admin] = true
  end

  config.before do |example|
    next unless example.metadata[:clover_admin]
    page.driver.header "Host", "admin.ubicloud.com"
  end
end
