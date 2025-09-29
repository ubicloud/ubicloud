# frozen_string_literal: true

source "https://rubygems.org"

# Update ruby version in Dockerfile and .tool_versions when updating this
ruby "3.4.6"

gem "acme-client"
gem "argon2"
gem "argon2-kdf"
gem "autoforme", github: "jeremyevans/autoforme", ref: "42d883177970cc6bd66b70239e21a425b335a379"
gem "aws-sdk-ec2", "~> 1.512"
gem "aws-sdk-iam"
gem "aws-sdk-s3"
gem "bcrypt_pbkdf"
gem "committee", ">= 5.5.4"
gem "countries"
gem "ed25519"
gem "erubi", ">= 1.5"
gem "excon"
gem "forme"
gem "jwt"
gem "mail"
gem "net-ssh"
gem "netaddr"
gem "nokogiri"
gem "octokit"
gem "omniauth-github"
gem "omniauth-google-oauth2"
gem "pagerduty", ">= 4.0"
gem "prawn"
gem "prawn-table"
gem "pry"
gem "puma", ">= 6.2.2"
gem "rack-unreloader", ">= 1.8"
gem "rake"
gem "refrigerator", ">= 1"
gem "reline" # Remove it when pry adds it as a dependency
gem "roda", ">= 3.96"
gem "rodauth", github: "jeremyevans/rodauth", ref: "f01bab524499eef21a21d83a9883a60a41dc0aeb"
gem "rodauth-omniauth", github: "janko/rodauth-omniauth", ref: "477810179ba0cab8d459be1a0d87dca5b57ec94b"
gem "rodish", ">= 2.0.1"
gem "rotp"
gem "rqrcode"
gem "sequel", ">= 5.96"
gem "sequel_pg", ">= 1.8", require: "sequel"
gem "shellwords"
gem "stripe"
gem "tilt", ">= 2.6.1"
gem "warning"
gem "webauthn"

group :development do
  gem "awesome_print"
  gem "by", ">= 1.1.0"
  gem "cuprite"
  gem "foreman"
  gem "pry-byebug"
  gem "rackup"
end

group :rubocop do
  gem "rubocop-capybara", "< 2.22"
  gem "rubocop-erb"
  gem "rubocop-performance"
  gem "rubocop-rake"
  gem "rubocop-rspec"
  gem "rubocop-sequel"
  gem "standard", ">= 1.24.3"
end

group :lint do
  gem "brakeman"
  gem "erb-formatter", github: "ubicloud/erb-formatter", ref: "df3174476986706828f7baf3e5e6f5ec8ecd849b"
end

group :test do
  gem "capybara"
  gem "capybara-validate_html5", ">= 2.1"
  gem "pdf-reader"
  gem "rspec"
  gem "simplecov"
  gem "turbo_tests"
  gem "webmock"
end

group :test, :development do
  gem "sequel-annotate"
end
