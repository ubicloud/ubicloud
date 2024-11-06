# frozen_string_literal: true

class Clover < Roda
  # rubocop:disable Style/OptionalArguments
  def self.autoload_routes(namespace = "", route)
    # rubocop:enable Style/OptionalArguments # different indents required by Rubocop
    route_path = "routes/#{route}"
    if Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
      Unreloader.require(route_path)
    else
      # :nocov:
      plugin :autoload_hash_branches
      Dir["#{route_path}/**/*.rb"].each do |full_path|
        parts = full_path.delete_prefix("#{route_path}/").split("/")
        namespaces = parts[0...-1]
        filename = parts.last
        if namespaces.empty?
          autoload_hash_branch(namespace, File.basename(filename, ".rb").tr("_", "-"), full_path)
        else
          autoload_hash_branch(:"#{namespace + "_" unless namespace.empty?}#{namespaces.join("_")}_prefix", File.basename(filename, ".rb").tr("_", "-"), full_path)
        end
      end
      Unreloader.autoload(route_path, delete_hook: proc { |f| hash_branch(File.basename(f, ".rb").tr("_", "-")) }) {}
      # :nocov:
    end
  end

  NAME_OR_UBID = /([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?)|_([a-z0-9]{26})/

  class RodaRequest
    def rodauth(name = scope.default_rodauth_name)
      super
    end

    # Do not allow session access in api routes
    def session
      # :nocov:
      raise(Roda::RodaError, "sessions are not used in api/runtime routes") unless scope.web?
      # :nocov:
      super
    end
  end

  class RodaResponse
    API_DEFAULT_HEADERS = DEFAULT_HEADERS.merge("content-type" => "application/json").freeze
    WEB_DEFAULT_HEADERS = DEFAULT_HEADERS.merge(
      "content-type" => "text/html",
      "x-frame-options" => "deny",
      "x-content-type-options" => "nosniff"
    )
    # :nocov:
    if Config.production?
      WEB_DEFAULT_HEADERS["strict-transport-security"] = "max-age=63072000; includeSubDomains"
    end
    # :nocov:
    WEB_DEFAULT_HEADERS.freeze

    attr_accessor :json

    def default_headers
      json ? API_DEFAULT_HEADERS : WEB_DEFAULT_HEADERS
    end

    def set_default_headers
      super
      # XXX: When using Roda 3.86.0, set response.content_security_policy = false instead in route
      headers.delete("content-security-policy") if json
    end
  end

  # XXX: Temporary unless PR 2084 is merged
  # :nocov:
  if Config.production?
    def api?
      return @is_api if defined?(@is_api)
      @is_api = env["HTTP_HOST"]&.start_with?("api.")
    end
  else
    def api?
      return @is_api if defined?(@is_api)
      @is_api = env["HTTP_HOST"]&.start_with?("api.") || env["PATH_INFO"].start_with?("/api")
    end
  end
  # :nocov:

  def runtime?
    !!@is_runtime
  end

  def web?
    return @is_web if defined?(@is_web)
    @is_web = !api? && !runtime?
  end

  def has_project_permission(actions)
    @project_permissions.intersection(Authorization.expand_actions(actions)).any?
  end

  def current_account
    return @current_account if defined?(@current_account)
    @current_account = Account[rodauth.session_value]
  end

  def json_params
    @params ||= api? ? request.body.read : request.params.reject { _1 == "_csrf" }.to_json
  end

  # Assign some HTTP response codes to common exceptions.
  def parse_error(e)
    case e
    when Sequel::ValidationFailed
      code = 400
      type = "InvalidRequest"
      message = e.to_s
    when CloverError
      code = e.code
      type = e.type
      message = e.message
      details = e.details
    else
      Clog.emit("route exception") { Util.exception_to_hash(e) }

      code = 500
      type = "UnexceptedError"
      message = "Sorry, we couldn’t process your request because of an unexpected error."
    end

    response.status = code

    {
      code: code,
      type: type,
      message: message,
      details: details
    }
  end

  def fetch_location_based_prices(*resource_types)
    # We use 1 month = 672 hours for conversion. Number of hours
    # in a month changes between 672 and 744, We are  also capping
    # billable hours to 672 while generating invoices. This ensures
    # that users won't see higher price in their invoice compared
    # to price calculator and also we charge same amount no matter
    # the number of days in a given month.
    BillingRate.rates.filter { resource_types.include?(_1["resource_type"]) }
      .group_by { [_1["resource_type"], _1["resource_family"], _1["location"]] }
      .map { |_, brs| brs.max_by { _1["active_from"] } }
      .each_with_object(Hash.new { |h, k| h[k] = h.class.new(&h.default_proc) }) do |br, hash|
      hash[br["location"]][br["resource_type"]][br["resource_family"]] = {
        hourly: br["unit_price"].to_f * 60,
        monthly: br["unit_price"].to_f * 60 * 672
      }
    end
  end

  def default_rodauth_name
    api? ? :api : nil
  end

  def rodauth(name = default_rodauth_name)
    super
  end
end
