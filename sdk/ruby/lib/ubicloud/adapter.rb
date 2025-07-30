# frozen_string_literal: true

require "json"

module Ubicloud
  # Ubicloud::Adapter is the base class for adapters used in Ubicloud's Ruby SDK.
  # Ubicloud's Ruby SDK uses adapters to allow for separate ways to access
  # Ubicloud's API.  Currently, the :net_http adapter is the recommended adapter.
  #
  # Ubicloud::Adapter subclasses must implement +call+ to handle sending the
  # request.  They should call +handle_response+ to handle responses to the
  # request.
  class Adapter
    ADAPTERS = {
      net_http: :NetHttp,
      rack: :Rack
    }.freeze
    private_constant :ADAPTERS

    # Require the related adapter file, and return the related adapter.
    def self.adapter_class(adapter_type)
      require_relative "adapter/#{adapter_type}"
      const_get(ADAPTERS.fetch(adapter_type))
    end

    # Issue a GET request to the API for the given path.
    def get(path, missing: :raise)
      call("GET", path, missing:)
    end

    # Issue a GET request to the API for the given path and parameters.
    def post(path, params = nil)
      call("POST", path, params:)
    end

    # Issue a DELETE request to the API for the given path.
    def delete(path)
      call("DELETE", path)
    end

    # Issue a PATCH request to the API for the given path and parameters.
    def patch(path, params = nil)
      call("PATCH", path, params:)
    end

    private

    # Handle responses to the requests made the library.  Non-200/204
    # are treated as errors and result in an Ubicloud::Error being raised.
    def handle_response(code, headers, body, missing: :raise)
      case code
      when 204
        nil
      when 200
        if headers["content-type"].include?("json")
          JSON.parse(body, symbolize_names: true)
        else
          body
        end
      else
        return if code == 404 && missing.nil?
        raise Error.new("unsuccessful response", code:, body:)
      end
    end
  end
end
