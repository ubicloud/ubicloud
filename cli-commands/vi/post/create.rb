# frozen_string_literal: true

UbiCli.on("vi").run_on("create") do
  desc "Register a virtual machine init script"

  banner "ubi vi vi-name create script"

  help_example 'ubi vi my-script-name create "$(cat path/to/script)"'

  args 1

  run do |script|
    id = sdk.vm_init_script.create(name: @sdk_object.name, script:).id
    response("Virtual machine init script registered with id: #{id}")
  end
end
