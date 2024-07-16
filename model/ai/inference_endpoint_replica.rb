# frozen_string_literal: true

require_relative "../../model"

class InferenceEndpointReplica < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :vm, key: :id, primary_key: :vm_id
  many_to_one :inference_endpoint

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy
end
