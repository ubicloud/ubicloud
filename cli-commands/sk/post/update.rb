# frozen_string_literal: true

UbiCli.on("sk").run_on("update") do
  desc "Update an SSH public key"

  banner "ubi sk (sk-id | sk-name) update public-key"

  help_example 'ubi sk my-sk-name update "$(cat ~/.ssh/id_ed25519.pub)"'

  args 1

  run do |public_key|
    @sdk_object.update_public_key(public_key)
    response("SSH public key with id #{@sdk_object.id} updated")
  end
end
