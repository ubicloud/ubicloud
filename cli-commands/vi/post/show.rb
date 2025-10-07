# frozen_string_literal: true

UbiCli.on("vi").run_on("show") do
  desc "Show details for a virtual machine init script"

  banner "ubi vi (vi-id | vi-name) show"

  run do
    vm_init_script = @sdk_object
    response([
      "id: ", vm_init_script.id, "\n",
      "name: ", vm_init_script.name, "\n",
      "script:\n", vm_init_script.script
    ])
  end
end
