# frozen_string_literal: true

class UbiCli
  on("ss").run_on("get") do
    desc "Get a secret value from the secret store"

    banner "ubi ss (ss-id | ss-name) get key"

    args 1

    run do |key|
      response(@sdk_object.get_secret(key))
    end
  end
end
