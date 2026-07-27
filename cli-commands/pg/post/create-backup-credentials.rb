# frozen_string_literal: true

class UbiCli
  on("pg").run_on("create-backup-credentials") do
    desc "Create temporary, read-only credentials for downloading PostgreSQL backups"

    options("ubi pg (location/pg-name | pg-id) create-backup-credentials [options]", key: :pg_backup_creds) do
      on("--format=format", "output format: table (default), env, or json")
    end

    run do |opts, command|
      format = opts[:pg_backup_creds][:format] || "table"
      unless %w[table env json].include?(format)
        raise Rodish::CommandFailure.new("invalid format #{format.inspect}, must be one of: table, env, json", command)
      end

      creds = sdk_object.create_backup_credentials

      body =
        case format
        when "env"
          # Shell-sourceable WAL-G/aws/mc environment, for `eval "$(...)"` in an automated job.
          <<~TEXT
            export AWS_ACCESS_KEY_ID='#{creds[:access_key_id]}'
            export AWS_SECRET_ACCESS_KEY='#{creds[:secret_access_key]}'
            export AWS_SESSION_TOKEN='#{creds[:session_token]}'
            export WALG_S3_PREFIX='s3://#{creds[:bucket]}'
            export AWS_ENDPOINT='#{creds[:endpoint]}'
            export AWS_REGION='#{creds[:region]}'
            export AWS_S3_FORCE_PATH_STYLE='true'
          TEXT
        when "json"
          "#{creds.to_json}\n"
        else
          <<~TEXT
            Bucket: #{creds[:bucket]}
            Endpoint: #{creds[:endpoint]}
            Region: #{creds[:region]}
            Access Key ID: #{creds[:access_key_id]}
            Secret Access Key: #{creds[:secret_access_key]}
            Session Token: #{creds[:session_token]}
            Expires At: #{creds[:expiration]}
          TEXT
        end

      response(body)
    end
  end
end
