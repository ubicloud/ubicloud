# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = "ubicloud"
  s.version = "0.1.0"
  s.summary = "Ubicloud Ruby SDK"
  s.authors = ["Ubicloud, Inc."]
  s.email = ["ruby-gem-owner@ubicloud.com"]
  s.homepage = "https://github.com/ubicloud/ubicloud/tree/main/sdk/ruby"
  s.license = "MIT"
  s.required_ruby_version = ">= 3.4"

  s.metadata = {
    "bug_tracker_uri" => "https://github.com/ubicloud/ubicloud/issues",
    "mailing_list_uri" => "https://github.com/ubicloud/ubicloud/discussions/new?category=q-a",
    "source_code_uri" => "https://github.com/ubicloud/ubicloud/tree/main/sdk/ruby"
  }

  s.files = %w[MIT-LICENSE] + Dir["lib/**/*.rb"]
  s.extra_rdoc_files = %w[MIT-LICENSE]
end
