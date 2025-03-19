# frozen_string_literal: true

UbiCli.on("lb").run_on("attach-vm") do
  desc "Attach a virtual machine to a load balancer"

  banner "ubi lb (location/lb-name | lb-id) attach-vm vm-id"

  args 1

  run do |vm_id|
    id = sdk_object.attach_vm(vm_id).id
    response("Attached VM with id #{vm_id} to load balancer with id #{id}")
  end
end
