# frozen_string_literal: true

UbiCli.on("ps").run_on("disconnect") do
  desc "Disconnect a private subnet from another private subnet"

  banner "ubi ps (location/ps-name|ps-id) disconnect ps-id"

  args 1

  run do |ps_id|
    if ps_id.include?("/")
      raise Rodish::CommandFailure, "invalid private subnet id format"
    end
    post(ps_path("/disconnect/#{ps_id}")) do |data|
      ["Disconnected private subnets with ids #{ps_id} and #{data["id"]}"]
    end
  end
end
