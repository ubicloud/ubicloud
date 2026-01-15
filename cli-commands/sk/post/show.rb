# frozen_string_literal: true

UbiCli.on("sk").run_on("show") do
  desc "Show details for an SSH public key"

  banner "ubi sk (sk-id | sk-name) show"

  run do
    ssh_public_key = @sdk_object
    response([
      "id: ", ssh_public_key.id, "\n",
      "name: ", ssh_public_key.name, "\n",
      "public key:\n", ssh_public_key.public_key
    ])
  end
end
