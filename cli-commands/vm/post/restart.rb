# frozen_string_literal: true

UbiCli.on("vm").run_on("restart") do
  desc "Restart a virtual machine"

  banner "ubi vm (location/vm-name|vm-id) restart"

  run do
    post(vm_path("/restart")) do |data|
      ["Scheduled restart of VM with id #{data["id"]}"]
    end
  end
end
