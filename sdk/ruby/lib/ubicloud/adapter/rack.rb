# frozen_string_literal: true

module Ubicloud
  class Adapter::Rack < Adapter
    def initialize(app:, env:, project_id:)
      @app = app
      @env = env
      @project_id = project_id
    end

    def call(method, path, params: nil)
      env = @env.merge(
        "REQUEST_METHOD" => method,
        "PATH_INFO" => "/project/#{@project_id}/#{path}",
        "rack.request.form_input" => nil,
        "rack.request.form_hash" => nil
      )
      params &&= params.to_json.force_encoding(Encoding::BINARY)
      env["rack.input"] = StringIO.new(params || "".b)
      env.delete("roda.json_params")

      status, _, rack_body = @app.call(env)
      body = +""
      rack_body.each { body << _1 }
      rack_body.close if rack_body.respond_to?(:close)

      handle_response(status, body)
    end
  end
end
