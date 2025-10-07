# frozen_string_literal: true

UbiCli.on("vi").run_on("rename") do
  desc "Rename a virtual machine init script"

  banner "ubi vi (vi-id | vi-name) rename new-name"

  args 1

  run do |name|
    @sdk_object.rename_to(name)
    response("Virtual machine init script with id #{@sdk_object.id} renamed to #{@sdk_object.name}")
  end
end
