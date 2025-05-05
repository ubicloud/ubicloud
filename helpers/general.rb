# frozen_string_literal: true

class Clover < Roda
  def self.name_or_ubid_for(model)
    # (\z)? to force a nil as first capture
    [/(\z)?(#{model.ubid_type}[a-tv-z0-9]{24})/, /([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?)/]
  end
  [Firewall, KubernetesCluster, LoadBalancer, PostgresResource, PrivateSubnet, Vm].each do |model|
    const_set(:"#{model.table_name.upcase}_NAME_OR_UBID", name_or_ubid_for(model))
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
  end

  def before_rodauth_create_account(account, name)
    account[:id] = Account.generate_uuid
    account[:name] = name
    Validation.validate_account_name(account[:name])
  end

  def after_rodauth_create_account(account_id)
    account = Account[account_id]
    account.create_project_with_default_policy("Default")
    ProjectInvitation.where(email: account.email).all do |inv|
      account.add_project(inv.project)
      inv.project.subject_tags_dataset.first(name: inv.policy)&.add_subject(account_id)
      inv.destroy
    end
  end

  def current_account_id
    rodauth.session_value
  end

  def current_personal_access_token_id
    rodauth.session["pat_id"]
  end

  def check_found_object(obj)
    unless obj
      response.status = if request.delete? && request.remaining_path.empty?
        no_authorization_needed
        204
      else
        404
      end
      request.halt
    end
  end

  def no_authorization_needed
    # Do nothing, this is a no-op method only used to check in the specs
    # that all requests have some form of authorization, or an explicit
    # indication that additional authorization is not needed
    nil
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
    if @project_permissions && object_id == @project.id
      fail Authorization::Unauthorized unless has_project_permission(actions)
    else
      each_authorization_id do |id|
        Authorization.authorize(@project.id, id, actions, object_id)
      end
    end
  end

  def has_permission?(actions, object_id)
    each_authorization_id.all? do |id|
      Authorization.has_permission?(@project.id, id, actions, object_id)
    end
  end

  def all_permissions(object_id)
    each_authorization_id.map do |id|
      Authorization.all_permissions(@project.id, id, object_id)
    end.reduce(:&)
  end

  def dataset_authorize(ds, actions)
    each_authorization_id do |id|
      ds = Authorization.dataset_authorize(ds, @project.id, id, actions)
    end
    ds
  end

  def has_project_permission(actions)
    if actions.is_a?(Array)
      !@project_permissions.intersection(actions).empty?
    else
      @project_permissions.include?(actions)
    end
  end

  def current_account
    return @current_account if defined?(@current_account)
    @current_account = Account[rodauth.session_value]
  end

  def check_visible_location
    # If location previously retrieved in project/location route, check that it is visible
    # This is called when creating resources in the api routes.
    #
    # If location not previously retrieved, require it be visible or tied to the current project
    # when retrieving it.  This is called when creating resources in the web routes.
    @location ||= Location.visible_or_for_project(@project.id).first(id: request.params["location"])
    handle_invalid_location unless @location&.visible_or_for_project?(@project.id)
  end

  def handle_invalid_location
    if api?
      # Only show locations globally visible or tied to the current project.
      valid_locations = Location.visible_or_for_project(@project.id).select_order_map(:display_name)
      response.write({error: {
        code: 404,
        type: "InvalidLocation",
        message: "Validation failed for following path components: location",
        details: {location: "Given location is not a valid location. Available locations: #{valid_locations.join(", ")}"}
      }}.to_json)
    end

    response.status = 404
    request.halt
  end

  def validate_request_params(required_keys, allowed_optional_keys = [], ignored_keys = [])
    params = request.params

    # Committee handles validation for API
    if web?
      missing_required_keys = required_keys - params.keys
      unless missing_required_keys.empty?
        fail Validation::ValidationFailed.new({body: "Request body must include required parameters: #{missing_required_keys.join(", ")}"})
      end
    end

    params
  end

  def fetch_location_based_prices(*resource_types)
    # We use 1 month = 672 hours for conversion. Number of hours
    # in a month changes between 672 and 744, We are  also capping
    # billable hours to 672 while generating invoices. This ensures
    # that users won't see higher price in their invoice compared
    # to price calculator and also we charge same amount no matter
    # the number of days in a given month.
    BillingRate.rates.filter { resource_types.include?(it["resource_type"]) }
      .group_by { [it["resource_type"], it["resource_family"], it["location"]] }
      .map { |_, brs| brs.max_by { it["active_from"] } }
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
