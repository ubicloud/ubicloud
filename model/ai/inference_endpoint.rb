# frozen_string_literal: true

require_relative "../../model"

class InferenceEndpoint < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :replicas, class: :InferenceEndpointReplica, key: :inference_endpoint_id
  one_to_one :load_balancer, key: :id, primary_key: :load_balancer_id
  one_to_one :private_subnet, key: :id, primary_key: :private_subnet_id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :root_cert_key
    enc.column :server_cert_key
  end

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/inference_endpoint/#{name}"
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/inference_endpoint/#{name}"
  end

  def self.redacted_columns
    super + [:root_cert, :server_cert]
  end
end
