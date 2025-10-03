# frozen_string_literal: true

UbiCli.on("vi").run_on("update") do
  desc "Update a virtual machine init script"

  banner "ubi vi (vi-id | vi-name) update script"

  help_example 'ubi vi my-script-name update "$(cat /path/to/script)"'

  args 1

  run do |script|
    @sdk_object.update_script(script)
    response("Virtual machine init script with id #{@sdk_object.id} updated")
  end
end
