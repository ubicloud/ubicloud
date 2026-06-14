# frozen_string_literal: true

class UbiCli
  on("ss").run_on("rename") do
    desc "Rename a secret store"

    banner "ubi ss (ss-id | ss-name) rename new-name"

    args 1

    run do |name|
      @sdk_object.rename_to(name)
      response("Secret store with id #{@sdk_object.id} renamed to #{@sdk_object.name}")
    end
  end
end
