# frozen_string_literal: true

class Prog::Test::Base < Prog::Base
  def fail_test(msg)
    strand.update(exitval: {msg:})
    hop_failed
  end

  def self.postgres_test_location_options(provider)
    if provider == "aws"
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      location.location_credential_aws ||
        LocationCredentialAws.create_with_id(location.id, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
      family = "m8gd"
      vcpus = 2
      [location.id, Option.aws_instance_type_name(family, vcpus), Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
    else
      [Location::HETZNER_FSN1_ID, "standard-2", 128]
    end
  end
end
