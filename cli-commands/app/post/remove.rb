# frozen_string_literal: true

UbiCli.on("app").run_on("remove") do
  desc "Remove (destroy) a VM from an app process"

  banner "ubi app (location/app-name | app-id) remove vm-name"

  args 1

  run do |vm_name|
    result = sdk_object.remove(vm_name: vm_name)
    response("#{result.name}  removed #{vm_name}\n")
  end
end
