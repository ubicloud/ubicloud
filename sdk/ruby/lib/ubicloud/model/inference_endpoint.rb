# frozen_string_literal: true

module Ubicloud
  class InferenceEndpoint < BaseModel
    extend BaseList

    set_prefix "ie"

    set_fragment "inference-endpoint"

    set_columns :id, :name, :display_name, :url, :model_name, :tags, :price

    def initialize(adapter, values)
      @adapter = adapter
      @values = values
    end
  end
end
