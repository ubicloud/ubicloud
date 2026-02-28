# frozen_string_literal: true

UbiCli.on("app").run_on("detach") do
  desc "Detach a VM from an app process"

  banner "ubi app (location/app-name | app-id) detach vm-name"

  args 1

  run do |vm_name|
    result = sdk_object.detach(vm_name: vm_name)
    response("#{result.name}  detached #{vm_name}\n")
  end
end
