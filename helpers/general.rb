# frozen_string_literal: true

class Clover < Roda
  def self.name_or_ubid_for(model)
    # (\z)? to force a nil as first capture
    [/(\z)?(#{model.ubid_type}[a-tv-z0-9]{24})/, /([a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?)/]
  end
  [Firewall, KubernetesCluster, LoadBalancer, PostgresResource, PrivateSubnet, Vm].each do |model|
    const_set(:"#{model.table_name.upcase}_NAME_OR_UBID", name_or_ubid_for(model))
  end

  # Designed only for compatibility with existing mocking in the specs
  def self.authorized_project(account, project_id)
    account.projects_dataset[Sequel[:project][:id] => project_id, :visible => true]
  end

  class RodaRequest
    def accepts_json?
      env["HTTP_ACCEPT"]&.include?("application/json")
    end

    def rename(object, perm:, serializer:, template_prefix:)
      post "rename" do
        scope.instance_exec do
          authorize(perm, object.id)
          handle_validation_failure("#{template_prefix}/show") { @page = "settings" }
          name = typecast_body_params.nonempty_str!("name")
          Validation.validate_name(name)

          DB.transaction do
            object.update(name:)
            audit_log(object, "update")
          end

          if api?
            serializer.serialize(object)
          else
            flash["notice"] = "Name updated"
            request.redirect object, "/settings"
          end
        end
      end
    end

    def show_object(object, actions:, perm:, template:)
      return unless web?

      get actions do |page|
        scope.instance_exec do
          authorize(perm, object.id)

          response.headers["cache-control"] = "no-store"
          @page = page
          view template
        end
      end
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
  end

  AUDIT_LOG_DS = DB[:audit_log].returning(nil)
  SUPPORTED_ACTIONS = Set.new(<<~ACTIONS.split.each(&:freeze)).freeze
    add_account
    add_invitation
    add_member
    associate
    attach_vm
    connect
    create
    create_replica
    destroy
    destroy_invitation
    detach_vm
    disassociate
    disconnect
    promote
    remove_account
    remove_member
    reset_superuser_password
    restart
    restore
    restrict
    set_maintenance_window
    unrestrict
    update
    update_billing
    update_invitation
  ACTIONS
  LOGGED_ACTIONS = Set.new(%w[create create_replica destroy promote reset_superuser_password restart restore update]).freeze

  def audit_log(object, action, objects = [])
    raise "unsupported audit_log action: #{action}" unless SUPPORTED_ACTIONS.include?(action)

    # Currently, only store create and destroy actions in non-test mode.
    # This can be removed later if we decide to expand to logging all actions.
    # :nocov:
    return unless LOGGED_ACTIONS.include?(action) || Config.test?
    # :nocov:

    project_id = @project.id
    subject_id = current_account.id
    ubid_type = object.class.ubid_type

    object_ids = Array(objects).map do
      case it
      when Sequel::Model
        it.id
      when String
        if it.length == 26
          UBID.to_uuid(it)
        else
          it
        end
      else
        it
      end
    end

    object_ids.compact!
    object_ids.unshift(object.id) unless object.is_a?(Project)
    object_ids = Sequel.pg_array(object_ids, :uuid)
    AUDIT_LOG_DS.insert(project_id:, ubid_type:, action:, subject_id:, object_ids:)
  end

  def before_authenticated_hash_branches
    # nothing, only existing for setting up test-specific code
  end

  def before_main_hash_branches
    # nothing, only existing for setting up test-specific code
  end

  def no_audit_log
    # Do nothing, this is a no-op method only used to check in the specs
    # that all non-GET requests have some form of audit logging, as an explicit
    # indication that audit logging is not needed
    nil
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
        no_authorization_needed if @still_need_authorization
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

  def authorized_object(key:, perm:, association: nil, id: nil, ds: @project.send(:"#{association}_dataset"), location_id: nil)
    if id ||= typecast_params.ubid_uuid(key)
      ds = dataset_authorize(ds, perm)
      ds = ds.where(location_id:) if location_id
      ds.first(id:)
    end
  end

  def check_visible_location
    # If location previously retrieved in project/location route, check that it is visible
    # This is called when creating resources in the api routes.
    #
    # If location not previously retrieved, require it be visible or tied to the current project
    # when retrieving it.  This is called when creating resources in the web routes.
    @location ||= if (id = typecast_params.ubid_uuid("location"))
      Location.visible_or_for_project(@project.id).first(id:)
    end
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
