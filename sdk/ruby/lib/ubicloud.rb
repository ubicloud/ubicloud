# frozen_string_literal: true

require_relative "ubicloud/adapter"
require_relative "ubicloud/model"
require_relative "ubicloud/model_adapter"
require_relative "ubicloud/context"

# The Ubicloud module is the namespace for Ubicloud's Ruby SDK,
# and also the primary entry point.  Even though it is a module,
# users are expected to call +Ubicloud.new+ to return an appropriate
# context (Ubicloud::Context) that is used to make requests to
# Ubicloud's API.
module Ubicloud
  # Error class used for errors raised by Ubicloud's Ruby SDK.
  class Error < StandardError
    # The integer HTTP status code related to the error.  Can be
    # nil if the Error is not related to an HTTP request.
    attr_reader :code

    # Accept the code and body keyword arguments for metadata
    # related to this error.
    def initialize(message, code: nil, body: nil)
      super(message)
      @code = code
      @body = body
    end

    # A hash of parameters.  This is the parsed JSON response body
    # for the request that resulted in an error.  If an invalid
    # body is given, or the error is not related to an HTTP request,
    # returns an empty hash.
    def params
      @body ? JSON.parse(@body) : {}
    rescue
      {}
    end
  end

  # Create a new Ubicloud::Context for the given adapter type
  # and parameters.  This is the main entry point to the library.
  # In general, users of the SDK will want to use the :net_http
  # adapter type:
  #
  #   Ubicloud.new(:net_http, token: "YOUR_API_TOKEN", project_id: "pj...")
  def self.new(adapter_type, **params)
    Context.new(Adapter.adapter_class(adapter_type).new(**params))
  end
end
