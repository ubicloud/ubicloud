# frozen_string_literal: true

UbiCli.on("fw").run_on("detach-subnet") do
  options("ubi fw location/(fw-name|_fw-ubid) detach-subnet subnet-id")

  args 1

  run do |subnet_id|
    post(fw_path("/detach-subnet"), "private_subnet_id" => subnet_id) do |data|
      ["Detached private subnet with id #{subnet_id} from firewall with id #{data["id"]}"]
    end
  end
end
