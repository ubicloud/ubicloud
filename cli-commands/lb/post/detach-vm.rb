# frozen_string_literal: true

UbiCli.on("lb").run_on("detach-vm") do
  desc "Detach a virtual machine from a load balancer"

  banner "ubi lb (location/lb-name | lb-id) detach-vm vm-id"

  args 1

  run do |vm_id|
    id = sdk_object.detach_vm(vm_id).id
    response("Detached VM with id #{vm_id} from load balancer with id #{id}")
  end
end
