# frozen_string_literal: true

UbiCli.on("sk").run_on("create") do
  desc "Register an SSH public key"

  banner "ubi sk sk-name create public-key"

  help_example 'ubi sk my-sk-name create "$(cat ~/.ssh/id_ed25519.pub)"'
  help_example 'ubi sk my-sk-name create "$(cat ~/.ssh/authorized_keys)"'

  args 1

  run do |public_key|
    id = sdk.ssh_public_key.create(name: @sdk_object.name, public_key:).id
    response("SSH public key registered with id: #{id}")
  end
end
