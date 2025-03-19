# frozen_string_literal: true

module Ubicloud
  class Adapter
    ADAPTERS = {
      net_http: :NetHttp,
      rack: :Rack
    }.freeze

    def self.adapter_class(adapter_type)
      require_relative "adapter/#{adapter_type}"
      const_get(ADAPTERS.fetch(adapter_type))
    end

    def get(path)
      call("GET", path)
    end

    def post(path, params = nil)
      call("POST", path, params:)
    end

    def delete(path, params = nil)
      call("DELETE", path, params:)
    end

    def patch(path, params = nil)
      call("PATCH", path, params:)
    end

    private

    def handle_response(status, body)
      case status
      when 204
        nil
      when 200
        JSON.parse(body, symbolize_names: true)
      else
        raise Error.new("unsuccessful response", status, body)
      end
    end
  end
end
