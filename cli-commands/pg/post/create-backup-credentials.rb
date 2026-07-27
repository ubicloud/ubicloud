# frozen_string_literal: true

class UbiCli
  on("pg").run_on("create-backup-credentials") do
    desc "Create temporary, read-only credentials for downloading PostgreSQL backups"

    banner "ubi pg (location/pg-name | pg-id) create-backup-credentials"

    run do
      creds = sdk_object.create_backup_credentials
      text = <<~TEXT
        Bucket: #{creds[:bucket]}
        Endpoint: #{creds[:endpoint]}
        Region: #{creds[:region]}
        Access Key ID: #{creds[:access_key_id]}
        Secret Access Key: #{creds[:secret_access_key]}
        Session Token: #{creds[:session_token]}
        Expires At: #{creds[:expiration]}
      TEXT
      text << "CA Certificate:\n#{creds[:ca_certificate]}" if creds[:ca_certificate]
      response(text)
    end
  end
end
