# frozen_string_literal: true

require "uri"
require "net/http"

module Ubicloud
  # Ubicloud::Adapter::NetHttp is the recommended adapter for general use.
  # It uses the net/http standard library to make requests to the Ubicloud API.
  class Adapter::NetHttp < Adapter
    # Set the token and project_id to use for requests.  The base_uri argument
    # can be used to access a self-hosted Ubicloud instance (or other Ubicloud
    # instance not hosted by Ubicloud).
    def initialize(token:, project_id:, base_uri: "https://api.ubicloud.com/")
      @base_uri = URI.join(URI(base_uri), "project/#{project_id}/")
      @headers = {
        "authorization" => "Bearer: #{token}",
        "content-type" => "application/json",
        "accept" => "text/plain",
        "connection" => "close"
      }.freeze
      @get_headers = @headers.dup
      @get_headers.delete("content-type")
      @get_headers.freeze
    end

    METHOD_MAP = {
      "GET" => :get,
      "POST" => :post,
      "DELETE" => :delete,
      "PATCH" => :patch
    }.freeze

    private_constant :METHOD_MAP

    private

    # Use Net::HTTP to submit a request to the Ubicloud API.
    def call(method, path, params: nil, missing: :raise)
      Net::HTTP.start(@base_uri.hostname, @base_uri.port, use_ssl: @base_uri.scheme == "https") do |http|
        path = URI.join(@base_uri, path).path

        response = case method
        when "GET"
          http.get(path, @get_headers)
        when "DELETE"
          http.delete(path, @headers)
        else
          http.send(METHOD_MAP.fetch(method), path, params&.to_json, @headers)
        end

        headers = response.to_hash.transform_values { (it.length == 1) ? it[0] : it }
        handle_response(response.code.to_i, headers, response.body, missing:)
      end
    end
  end
end
