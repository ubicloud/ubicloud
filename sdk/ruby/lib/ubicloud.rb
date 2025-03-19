# frozen_string_literal: true

require_relative "ubicloud/adapter"
require_relative "ubicloud/model"
require_relative "ubicloud/model_adapter"
require_relative "ubicloud/context"

module Ubicloud
  class Error < StandardError
    attr_reader :code

    def initialize(message, code, body)
      super(message)
      @code = code
      @body = body
    end

    def params
      JSON.parse(@body)
    rescue
      {}
    end
  end

  def self.new(adapter_type, **params)
    Context.new(Adapter.adapter_class(adapter_type).new(**params))
  end
end
