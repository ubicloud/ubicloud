# frozen_string_literal: true

require "uri"
require "json"
require "net/http"

module Ubicloud
  class Adapter::NetHttp < Adapter
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

    def call(method, path, params: nil)
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

        handle_response(response.code.to_i, response.body)
      end
    end
  end
end
