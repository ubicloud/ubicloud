# frozen_string_literal: true

module Ubicloud
  # Ubicloud::Adapter::Rack is designed for internal use of the
  # Ruby SDK by Ubicloud itself.  It is used inside Ubicloud to
  # issue internal requests when handling CLI commands.  A new
  # instance of Ubicloud::Adapter::Rack is created for each
  # CLI command.
  class Adapter::Rack < Adapter
    # Accept the rack application (Clover), request env of the CLI request,
    # and related project id.
    def initialize(app:, env:, project_id:)
      @app = app
      @env = env
      @project_id = project_id
    end

    private

    # Create a new rack request enviroment hash for the internal
    # request, and call the rack application with it.
    def call(method, path, params: nil, missing: :raise)
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
      rack_body.each { body << it }
      rack_body.close if rack_body.respond_to?(:close)

      handle_response(status, body, missing:)
    end
  end
end
