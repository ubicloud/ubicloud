# frozen_string_literal: true

class Prog::Test::Base < Prog::Base
  def fail_test(msg)
    strand.update(exitval: {msg:})
    hop_failed
  end

  # Returns [location_id, target_vm_size, target_storage_size_gib] for the
  # requested e2e provider, ensuring provider credentials exist in the DB.
  # Used by postgres e2e test progs that run the same resource-shape selection
  # across providers.
  def e2e_postgres_provider_setup(provider, family: nil)
    case provider
    when "aws"
      location = Location[provider: "aws", project_id: nil, name: "us-west-2"]
      unless LocationCredentialAws[location.id]
        LocationCredentialAws.create_with_id(location, access_key: Config.e2e_aws_access_key, secret_key: Config.e2e_aws_secret_key)
      end
      family = "m8gd"
      vcpus = 2
      [location.id, Option.aws_instance_type_name(family, vcpus), Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
    when "gcp"
      location = Location[provider: "gcp", project_id: nil]
      unless LocationCredentialGcp[location.id]
        LocationCredentialGcp.create_with_id(location,
          credentials_json: Config.e2e_gcp_credentials_json,
          project_id: Config.e2e_gcp_project_id,
          service_account_email: Config.e2e_gcp_service_account_email)
      end
      family ||= "c4a-standard"
      vcpus = Option::GCP_STORAGE_SIZE_OPTIONS[family].keys.first
      [location.id, "#{family}-#{vcpus}", Option::GCP_STORAGE_SIZE_OPTIONS[family][vcpus].first.to_i]
    else
      [Location::HETZNER_FSN1_ID, "standard-2", 128]
    end
  end
end
