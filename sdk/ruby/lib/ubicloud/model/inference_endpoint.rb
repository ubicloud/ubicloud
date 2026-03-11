# frozen_string_literal: true

module Ubicloud
  class InferenceEndpoint < Model
    set_prefix "ie"

    set_fragment "inference-endpoint"

    set_columns :id, :name, :display_name, :url, :model_name, :tags, :price

    # Do not support a specific location when getting a list of inference endpoints.
    def self.list(adapter)
      super
    end
  end
end
