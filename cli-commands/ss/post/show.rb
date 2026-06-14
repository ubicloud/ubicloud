# frozen_string_literal: true

class UbiCli
  on("ss").run_on("show") do
    desc "Show details for a secret store"

    banner "ubi ss (ss-id | ss-name) show"

    run do
      ss = @sdk_object
      keys = ss.list_secrets
      response([
        "id: ", ss.id, "\n",
        "name: ", ss.name, "\n",
        "description: ", ss.description.to_s, "\n",
        "keys:\n",
        *keys.map { "  #{it}\n" },
      ])
    end
  end
end
