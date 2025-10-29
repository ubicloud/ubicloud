# frozen_string_literal: true

require "aws-sdk-rds"

DEFAULT_GENERATOR = Aws::RDS::AuthTokenGenerator.new

def generate_rds_iam_auth_token(options, generator = DEFAULT_GENERATOR)
  generator.generate_auth_token(options)
end

RDS_REGION_REGEX = /^.*?\..*?\.([a-z0-9-]+)\.rds\.amazonaws\.com$/

def substitute_rds_iam_auth_token(url, generator = DEFAULT_GENERATOR)
  uri = case url.is_a?
  when String
    URI.parse(url)
  when URI
    url
  else
    fail "Invalid type for url"
  end
  matches = uri.host.match RDS_REGION_REGEX
  fail "Invalid URL" if matches.nil?
  region = matches[1]
  endpoint = [uri.host, uri.port].join ":"
  user_name = uri.user

  uri.password = generate_rds_iam_auth_token({region: region, endpoint: endpoint, user_name: user_name}, generator)
  uri.to_s
end
