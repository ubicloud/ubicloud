# frozen_string_literal: true

class UbiCli
  on("ss").run_on("set") do
    desc "Set a secret in the secret store"

    banner "ubi ss (ss-id | ss-name) set key value"

    args 2

    run do |key, value|
      @sdk_object.set_secret(key, value)
      response("Secret #{key} set in secret store with id #{@sdk_object.id}")
    end
  end
end
