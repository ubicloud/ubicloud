# frozen_string_literal: true

class Routes::Common::Base
  module AppMode
    API = :api
    WEB = :web
  end

  def initialize(app:, request:, user:, location:, resource:)
    @app = app
    @request = request
    @user = user
    @resource = resource
    @location = location
    @mode = app.api? ? AppMode::API : AppMode::WEB
  end

  def project
    @app.instance_variable_get(:@project)
  end

  def response
    @app.response
  end

  def flash
    @app.flash
  end

  def params
    @params ||= (@mode == AppMode::API) ? @request.body.read : @request.params.reject { _1 == "_csrf" }.to_json
  end
end
