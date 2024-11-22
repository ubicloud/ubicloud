# frozen_string_literal: true

class Clover < Roda
  NAME_OR_UBID = /([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?)|_([a-z0-9]{26})/

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
  end

  def api?
    return @is_api if defined?(@is_api)
    @is_api = env["HTTP_HOST"].to_s.start_with?("api.")
  end

  def runtime?
    !!@is_runtime
  end

  def web?
    return @is_web if defined?(@is_web)
    @is_web = !api? && !runtime?
  end

  def current_account_id
    rodauth.session_value
  end

  def authorize(actions, object_id)
    Authorization.authorize(current_account_id, actions, object_id)
  end

  def has_permission?(actions, object_id)
    Authorization.has_permission?(current_account_id, actions, object_id)
  end

  def all_permissions(actions)
    Authorization.all_permissions(current_account_id, actions)
  end

  def dataset_authorize(ds, actions)
    ds.authorized(current_account_id, actions)
  end

  def has_project_permission(actions)
    @project_permissions.intersection(Authorization.expand_actions(actions)).any?
  end

  def current_account
    return @current_account if defined?(@current_account)
    @current_account = Account[rodauth.session_value]
  end

  def validate_request_params(required_keys, allowed_optional_keys = [])
    params = if api?
      begin
        request.params
      rescue Roda::RodaPlugins::InvalidRequestBody::Error
        raise Validation::ValidationFailed.new({body: "Request body isn't a valid JSON object."})
      end
    else
      request.params.reject { _1 == "_csrf" }
    end
    Validation.validate_request_params(params, required_keys, allowed_optional_keys)
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
end
