# frozen_string_literal: true

class UbiCli
  on("pg").run_on("download-managed-role-cert") do
    desc "Download the client certificate and key for a managed role"

    banner "ubi pg (location/pg-name | pg-id) download-managed-role-cert role-name"

    args 1

    run do |role_name, _, cmd|
      check_no_slash(role_name, "invalid managed role name, should not include /", cmd)
      response(sdk_object.download_managed_role_certificate(role_name))
    end
  end
end
