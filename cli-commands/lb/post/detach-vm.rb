# frozen_string_literal: true

UbiCli.on("lb").run_on("detach-vm") do
  desc "Detach a virtual machine from a load balancer"

  banner "ubi lb (location/lb-name | lb-id) detach-vm (vm-name | vm-id)"

  args 1

  run do |vm_id|
    id = sdk_object.detach_vm(convert_name_to_id(sdk.vm, vm_id)).id
    response("Detached VM #{vm_id} from load balancer with id #{id}")
  end
end
