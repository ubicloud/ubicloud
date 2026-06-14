# frozen_string_literal: true

class UbiCli
  on("ss").run_on("unset") do
    desc "Delete a secret from the secret store"

    banner "ubi ss (ss-id | ss-name) unset key"

    args 1

    run do |key|
      @sdk_object.delete_secret(key)
      response("Secret #{key} deleted from secret store with id #{@sdk_object.id}")
    end
  end
end
