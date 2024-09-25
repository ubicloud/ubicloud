# frozen_string_literal: true

require_relative "../../model"

class InferenceEndpoint < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :replicas, class: :InferenceEndpointReplica, key: :inference_endpoint_id
  one_to_one :load_balancer, key: :id, primary_key: :load_balancer_id
  one_to_one :private_subnet, key: :id, primary_key: :private_subnet_id
  one_to_many :api_keys, key: :owner_id, class: :ApiKey, conditions: {owner_table: "inference_endpoint", used_for: "inference_endpoint"}

  plugin :association_dependencies, api_keys: :destroy
  dataset_module Authorization::Dataset
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/inference-endpoint/#{name}"
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/inference-endpoint/#{name}"
  end

  def display_state
    return "running" if ["wait"].include?(strand.label)
    return "deleting" if destroy_set? || strand.label == "destroy"
    "creating"
  end

  def chat_completion_request(content, hostname, api_key)
    uri = URI.parse("#{load_balancer.health_check_protocol}://#{hostname}/v1/chat/completions")
    header = {"Content-Type": "application/json", Authorization: "Bearer " + api_key}
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 30
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if Config.development?
    http.use_ssl = (uri.scheme == "https")
    req = Net::HTTP::Post.new(uri.request_uri, header)
    req.body = {model: model_name, messages: [{role: "user", content: content}]}.to_json
    http.request(req)
  end
end
