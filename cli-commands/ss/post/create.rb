# frozen_string_literal: true

class UbiCli
  on("ss").run_on("create") do
    desc "Create a secret store"

    options("ubi ss ss-name create [options]", key: :ss_create) do
      on("-d", "--description=desc", "description for the secret store")
    end

    run do |opts|
      params = underscore_keys(opts[:ss_create])
      id = sdk.secret_store.create(name: @sdk_object.name, **params).id
      response("Secret store created with id: #{id}")
    end
  end
end
