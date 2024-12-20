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

  def current_account_id
    rodauth.session_value
  end

  def current_personal_access_token_id
    rodauth.session["pat_id"]
  end

  private def each_authorization_id
    return to_enum(:each_authorization_id) unless block_given?

    yield current_account_id
    if (pat_id = current_personal_access_token_id)
      yield pat_id
    end
    nil
  end

  def authorize(actions, object_id)
    each_authorization_id do |id|
      Authorization.authorize(id, actions, object_id)
    end
  end

  def has_permission?(actions, object_id)
    each_authorization_id.all? do |id|
      Authorization.has_permission?(id, actions, object_id)
    end
  end

  def all_permissions(actions)
    each_authorization_id.map do |id|
      Authorization.all_permissions(id, actions)
    end.reduce(:&)
  end

  def dataset_authorize(ds, actions)
    each_authorization_id do |id|
      ds = ds.authorized(id, actions)
    end
    ds
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
      request.params
    else
      request.params.reject { _1 == "_csrf" }
    end
    Validation.validate_request_params(params, required_keys, allowed_optional_keys)
  end

  def fetch_location_based_prices(*resource_types)
    # We use 1 month = 730 hours for conversion, which is the average number of hours in a month.
    BillingRate.rates.filter { resource_types.include?(_1["resource_type"]) }
      .group_by { [_1["resource_type"], _1["resource_family"], _1["location"]] }
      .map { |_, brs| brs.max_by { _1["active_from"] } }
      .each_with_object(Hash.new { |h, k| h[k] = h.class.new(&h.default_proc) }) do |br, hash|
      hash[br["location"]][br["resource_type"]][br["resource_family"]] = {
        hourly: br["unit_price"].to_f * 60,
        monthly: br["unit_price"].to_f * 60 * 730
      }
    end
  end

  def default_rodauth_name
    api? ? :api : nil
  end
end
