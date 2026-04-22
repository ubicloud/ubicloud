# frozen_string_literal: true

class Prog::Test::Base < Prog::Base
  def fail_test(msg)
    strand.update(exitval: {msg:})
    hop_failed
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
end
