# frozen_string_literal: true

require "excon"
require "json"

class RunpodClient
  def initialize
    @connection = Excon.new("https://rest.runpod.io", headers: {"Content-Type" => "application/json", "Authorization" => "Bearer #{Config.runpod_api_key}"})
  end

  def create_pod(name, config)
    response = @connection.get(path: "v1/pods", query: {name: name}, expects: 200)
    pods = JSON.parse(response.body)
    return pods.first["id"] if pods.any?

    response = @connection.post(path: "v1/pods", body: config.to_json)
    fail "Failed to create pod: #{response.status} #{response.body}" unless response.status == 201

    pod = JSON.parse(response.body)
    pod["id"]
  end

  def get_pod(pod_id)
    response = @connection.get(path: "v1/pods/#{pod_id}", expects: 200)
    JSON.parse(response.body)
  end

  def delete_pod(pod_id)
    @connection.delete(path: "v1/pods/#{pod_id}", expects: 200)
  end
end
