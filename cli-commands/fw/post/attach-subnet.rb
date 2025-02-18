# frozen_string_literal: true

UbiCli.on("fw").run_on("attach-subnet") do
  options("ubi fw location/(fw-name|_fw-ubid) attach-subnet subnet-id")

  args 1

  run do |subnet_id|
    post(fw_path("/attach-subnet"), "private_subnet_id" => subnet_id) do |data|
      ["Attached private subnet with id #{subnet_id} to firewall with id #{data["id"]}"]
    end
  end
end
