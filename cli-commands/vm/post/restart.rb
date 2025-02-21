# frozen_string_literal: true

UbiCli.on("vm").run_on("restart") do
  options("ubi vm location/(vm-name|_vm-id) restart")

  run do
    post(vm_path("/restart")) do |data|
      ["Scheduled restart of VM with id #{data["id"]}"]
    end
  end
end
