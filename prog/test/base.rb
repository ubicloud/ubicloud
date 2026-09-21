# frozen_string_literal: true

class Prog::Test::Base < Prog::Base
  def fail_test(msg)
    strand.update(exitval: {msg:})
    hop_failed
  end

  def firewall_rules_applied?(*subnets)
    subnets.none?(&:update_firewall_rules_set?) &&
      subnets.flat_map { it.vms_dataset.eager(:strand, :semaphores).all }.none? { |vm| vm.update_firewall_rules_set? || vm.strand.label != "wait" }
  end

  # Shared between bin/e2e and Prog::Test::PostgresBase.postgres_test_location_options:
  # decodes the base64-encoded credentials Config and creates LocationCredentialGcp for
  # the given location unless it already exists. project_id and service_account_email
  # are extracted from the service-account JSON so we don't carry them as separate
  # Config values.
  def self.ensure_gcp_e2e_credential(location)
    return if LocationCredentialGcp[location.id]
    credentials_json = Base64.decode64(Config.e2e_gcp_credentials_base64_json)
    parsed = JSON.parse(credentials_json)
    LocationCredentialGcp.create_with_id(location,
      credentials_json:,
      project_id: parsed["project_id"],
      service_account_email: parsed["client_email"])
  end

  # Prefer IAM assume-role auth when Config.e2e_aws_assume_role is set,
  # otherwise fall back to static access_key/secret_key
  def self.ensure_aws_e2e_credential(location)
    return if LocationCredentialAws[location.id]
    assume_role = Config.e2e_aws_assume_role
    access_key = Config.e2e_aws_access_key
    secret_key = Config.e2e_aws_secret_key
    if assume_role && (access_key || secret_key)
      raise "e2e_aws_assume_role cannot be combined with e2e_aws_access_key/e2e_aws_secret_key"
    end
    if assume_role
      LocationCredentialAws.create_with_id(location, assume_role:)
    else
      LocationCredentialAws.create_with_id(location, access_key:, secret_key:)
    end
  end
end
