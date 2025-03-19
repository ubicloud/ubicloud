# frozen_string_literal: true

module Ubicloud
  class ModelAdapter
    def initialize(model, adapter)
      @model = model
      @adapter = adapter
    end

    def method_missing(meth, ...)
      @model.public_send(meth, @adapter, ...)
    end

    def respond_to_missing?(...)
      @model.respond_to?(...)
    end
  end
end
