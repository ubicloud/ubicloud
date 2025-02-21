# frozen_string_literal: true

UbiCli.on("lb").run_on("detach-vm") do
  options("ubi lb location/(lb-name|_lb-id) detach-vm vm-id")

  args 1

  run do |vm_id|
    post(lb_path("/detach-vm"), "vm_id" => vm_id) do |data|
      ["Detached VM with id #{vm_id} from load balancer with id #{data["id"]}"]
    end
  end
end
