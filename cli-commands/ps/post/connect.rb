# frozen_string_literal: true

UbiCli.on("ps").run_on("connect") do
  options("ubi ps location/(ps-name|_ps-ubid) connect ps-id")

  args 1

  run do |ps_id|
    post(ps_path("/connect"), "connected-subnet-ubid" => ps_id) do |data|
      ["Connected private subnets with ids #{ps_id} and #{data["id"]}"]
    end
  end
end
