# frozen_string_literal: true

require_relative "../../model"

class InferenceEndpoint < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :replicas, class: :InferenceEndpointReplica, key: :inference_endpoint_id
  one_to_one :load_balancer, key: :id, primary_key: :load_balancer_id
  one_to_one :private_subnet, key: :id, primary_key: :private_subnet_id
  many_to_one :location, key: :location_id, class: :Location

  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include ObjectTag::Cleanup

  semaphore :destroy, :maintenance

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/inference-endpoint/#{name}"
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

# Table: inference_endpoint
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  created_at        | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at        | timestamp with time zone | NOT NULL DEFAULT now()
#  is_public         | boolean                  | NOT NULL DEFAULT false
#  visible           | boolean                  | NOT NULL DEFAULT true
#  location          | text                     | NOT NULL
#  boot_image        | text                     | NOT NULL
#  name              | text                     | NOT NULL
#  vm_size           | text                     | NOT NULL
#  model_name        | text                     | NOT NULL
#  storage_volumes   | jsonb                    | NOT NULL
#  engine            | text                     | NOT NULL
#  engine_params     | text                     | NOT NULL
#  replica_count     | integer                  | NOT NULL
#  project_id        | uuid                     | NOT NULL
#  load_balancer_id  | uuid                     | NOT NULL
#  private_subnet_id | uuid                     | NOT NULL
#  gpu_count         | integer                  | NOT NULL DEFAULT 1
#  tags              | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  max_requests      | integer                  | NOT NULL DEFAULT 500
#  max_project_rps   | integer                  | NOT NULL DEFAULT 100
#  max_project_tps   | integer                  | NOT NULL DEFAULT 10000
#  location_id       | uuid                     |
# Indexes:
#  inference_endpoint_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  inference_endpoint_load_balancer_id_fkey  | (load_balancer_id) REFERENCES load_balancer(id)
#  inference_endpoint_location_id_fkey       | (location_id) REFERENCES location(id)
#  inference_endpoint_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  inference_endpoint_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  inference_endpoint_replica | inference_endpoint_replica_inference_endpoint_id_fkey | (inference_endpoint_id) REFERENCES inference_endpoint(id)
