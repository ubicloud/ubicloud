# frozen_string_literal: true

class UbiCli
  on("pg").run_on("ca-certificates") do
    desc "Print CA certificates for a PostgreSQL database (if available)"

    banner "ubi pg (location/pg-name | pg-id) ca-certificates"

    run do |_, cmd|
      unless (certs = sdk_object.ca_certificates)
        cmd.raise_failure(<<~END)
          CA certificates are not available for this database, either because it uses
          publicly signed certificates or because a CA certificate has not been generated
          yet.
        END
      end
      response(certs)
    end
  end
end
