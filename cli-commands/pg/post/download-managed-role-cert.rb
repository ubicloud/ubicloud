# frozen_string_literal: true

class UbiCli
  on("pg").run_on("download-managed-role-cert") do
    desc "Download the client certificate and key for a managed role"

    banner "ubi pg (location/pg-name | pg-id) download-managed-role-cert role-name"

    args 1

    run do |role_name, _, cmd|
      response(sdk_object.download_managed_role_certificate(role_name))
    rescue Ubicloud::Error => e
      # Surface client-side errors (no HTTP status) as clean CLI failures;
      # let server responses fall through to the default error handler.
      raise unless e.code.nil?
      cmd.raise_failure(e.message)
    end
  end
end
