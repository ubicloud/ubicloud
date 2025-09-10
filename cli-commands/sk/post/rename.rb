# frozen_string_literal: true

UbiCli.on("sk").run_on("rename") do
  desc "Rename an SSH public key"

  banner "ubi sk (sk-id | sk-name) rename new-name"

  args 1

  run do |name|
    @sdk_object.rename_to(name)
    response("SSH public key with id #{@sdk_object.id} renamed to #{@sdk_object.name}")
  end
end
