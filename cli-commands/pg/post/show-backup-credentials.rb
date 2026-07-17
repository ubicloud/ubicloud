# frozen_string_literal: true

class UbiCli
  on("pg").run_on("show-backup-credentials") do
    desc "Show temporary, read-only credentials for downloading PostgreSQL backups"

    banner "ubi pg (location/pg-name | pg-id) show-backup-credentials"

    run do
      creds = sdk_object.backup_credentials
      response(<<~TEXT)
        Bucket: #{creds[:bucket]}
        Endpoint: #{creds[:endpoint]}
        Region: #{creds[:region]}
        Access Key ID: #{creds[:access_key_id]}
        Secret Access Key: #{creds[:secret_access_key]}
        Session Token: #{creds[:session_token]}
        Expires At: #{creds[:expiration]}
      TEXT
    end
  end
end
