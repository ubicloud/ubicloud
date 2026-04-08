# frozen_string_literal: true

class Prog::Test::Base < Prog::Base
  def fail_test(msg)
    strand.update(exitval: {msg:})
    hop_failed
  end

  def self.postgres_test_location_options(provider, family: nil)
    if provider == "aws"
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      location.location_credential_aws ||
        LocationCredentialAws.create_with_id(location.id, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
      aws_family = "m8gd"
      vcpus = 2
      [location.id, Option.aws_instance_type_name(aws_family, vcpus), Option::AWS_STORAGE_SIZE_OPTIONS[aws_family][vcpus].first.to_i]
    elsif provider == "gcp"
      location = Location[provider: "gcp", project_id: nil]
      unless LocationCredentialGcp[location.id]
        LocationCredentialGcp.create_with_id(location.id,
          credentials_json: Config.e2e_gcp_credentials_json,
          project_id: Config.e2e_gcp_project_id,
          service_account_email: Config.e2e_gcp_service_account_email)
      end
      gcp_family = family || "c4a-standard"
      vcpus = Option::GCP_STORAGE_SIZE_OPTIONS[gcp_family].keys.first
      [location.id, "#{gcp_family}-#{vcpus}", Option::GCP_STORAGE_SIZE_OPTIONS[gcp_family][vcpus].first.to_i]
    else
      [Location::HETZNER_FSN1_ID, "standard-2", 128]
    end
  end
end
