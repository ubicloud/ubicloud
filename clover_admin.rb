# frozen_string_literal: true

require_relative "model"

require "roda"
require "tilt"
require "tilt/erubi"
require "openssl"

class CloverAdmin < Roda
  # :nocov:
  plugin :exception_page if Config.development?
  default_fixed_locals = if Config.production? || Config.frozen_test?
    "()"
  # :nocov:
  else
    "(_no_kw: nil)"
  end

  plugin :render, views: "views/admin", escape: true, assume_fixed_locals: true, template_opts: {
    chain_appends: !defined?(SimpleCov),
    freeze: true,
    skip_compiled_encoding_detection: true,
    scope_class: self,
    default_fixed_locals:,
    extract_fixed_locals: true
  }

  plugin :part
  plugin :public
  plugin :flash
  plugin :h

  plugin :content_security_policy do |csp|
    csp.default_src :none
    csp.style_src :self
    csp.img_src :self    # /favicon.ico
    csp.script_src :self # webauthn
    csp.form_action :self
    csp.base_uri :none
    csp.frame_ancestors :none
  end

  plugin :sessions,
    key: "_CloverAdmin.session",
    cookie_options: {secure: !(Config.development? || Config.test?)},
    secret: OpenSSL::HMAC.digest("SHA512", Config.clover_session_secret, "admin-site")

  UBID_REGEXP = /\A[a-tv-z0-9]{26}\z/
  UUID_REGEXP = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/i

  plugin :typecast_params_sized_integers, sizes: [64], default_size: 64
  plugin :typecast_params do
    handle_type(:ubid) do
      it if UBID_REGEXP.match?(it)
    end

    handle_type(:uuid) do
      it if UUID_REGEXP.match?(it)
    end

    handle_type(:ubid_uuid) do
      UBID.to_uuid(it) if UBID_REGEXP.match?(it)
    end
  end

  plugin :symbol_matchers
  symbol_matcher(:ubid, /([a-tv-z0-9]{26})/)

  plugin :not_found do
    raise "admin route not handled: #{request.path}" if Config.test? && !ENV["DONT_RAISE_ADMIN_ERRORS"]

    @page_title = "File Not Found"
    view(content: "")
  end

  plugin :route_csrf do |token|
    flash.now["error"] = "An invalid security token submitted with this request, please try again"
    @page_title = "Invalid Security Token"
    view(content: "")
  end

  plugin :error_handler do |e|
    raise e if Config.test? && !ENV["DONT_RAISE_ADMIN_ERRORS"]

    Clog.emit("admin route exception", Util.exception_to_hash(e))
    @page_title = if e.is_a?(CloverError)
      "#{e.type}: #{e.message}"
    else
      "Internal Server Error"
    end
    view(content: "")
  end

  plugin :forme_route_csrf
  Forme.register_config(:clover_admin, base: :default, labeler: :explicit)
  Forme.default_config = :clover_admin

  def self.create_admin_account(login)
    if Config.production? && defined?(Pry)
      raise "cannot create admin account in production via pry as it would log the password"
    end

    password = SecureRandom.urlsafe_base64(16)
    password_hash = rodauth.new(nil).password_hash(password)
    DB.transaction do
      id = DB[:admin_account].insert(login:)
      DB[:admin_password_hash].insert(id:, password_hash:)
    end
    Clog.emit("Created admin account", {admin_account_created: login})
    password
  end

  def linkify_ubids(body)
    h(body).gsub(/\b[a-tv-z0-9]{26}\b/) do
      if (klass = UBID.class_for_ubid(it))
        "<a href=\"/model/#{klass}/#{it}\">#{it}</a>"
      else
        it
      end
    end
  end

  def available_classes
    classes = []
    Sequel::Model.subclasses.each do |c|
      classes << c if c < ResourceMethods::InstanceMethods
      c.subclasses.each do |sc|
        classes << sc if sc < ResourceMethods::InstanceMethods
      end
    end
    classes.sort_by!(&:name)
  end

  skip_webauthn_requirement = Config.development? && Config.clover_admin_development_no_webauthn?

  plugin :rodauth, route_csrf: true do
    enable :argon2, :login, :logout, :webauthn, :change_password
    accounts_table :admin_account
    password_hash_table :admin_password_hash
    webauthn_keys_table :admin_webauthn_key
    webauthn_user_ids_table :admin_webauthn_user_id
    login_column :login

    # :nocov:
    unless skip_webauthn_requirement
      # :nocov:
      login_redirect do
        uses_two_factor_authentication? ? "/webauthn-auth" : "/webauthn-setup"
      end
    end

    check_csrf? false
    require_bcrypt? false
    title_instance_variable :@page_title
    argon2_secret OpenSSL::HMAC.digest("SHA256", Config.clover_session_secret, "admin-argon2-secret")
    hmac_secret OpenSSL::HMAC.digest("SHA512", Config.clover_session_secret, "admin-rodauth-hmac-secret")
    function_name(&{
      rodauth_get_salt: :rodauth_admin_get_salt,
      rodauth_valid_password_hash: :rodauth_admin_valid_password_hash
    }.to_proc)

    password_minimum_length 16
    password_maximum_bytes 72
    password_meets_requirements? do |password|
      super(password) && password.match?(/[a-z]/) && password.match?(/[A-Z]/) && password.match?(/[0-9]/)
    end
  end

  ObjectAction = Data.define(:label, :flash, :params, :action) do
    def self.define(label, flash, params = {}, &action)
      new(label, flash, params.dup.freeze, action)
    end

    def call(...)
      action.call(...)
    end
  end

  def self.object_action(...)
    ObjectAction.define(...)
  end

  OBJECT_ACTIONS = {
    "Account" => {
      "suspend" => object_action("Suspend", "Account suspended", &:suspend)
    },
    "GithubRunner" => {
      "provision" => object_action("Provision Spare Runner", "Spare runner provisioned", &:provision_spare_runner)
    },
    "Page" => {
      "resolve" => object_action("Resolve", "Resolve scheduled for Page", &:incr_resolve)
    },
    "PostgresResource" => {
      "restart" => object_action("Restart", "Restart scheduled for PostgresResource", &:incr_restart)
    },
    "Project" => {
      "add_credit" => object_action("Add credit", "Added credit", {credit: "float!"}) do |obj, credit|
        obj.this.update(credit: Sequel[:credit] + credit)
      end,
      "set_feature_flag" => object_action("Set Feature Flag", "Set feature flag", {
        name: {
          typecast: :str!,
          type: "select",
          add_blank: true,
          options: Project.instance_methods.filter_map { it.to_s.delete_prefix("set_ff_") if it.start_with?("set_ff_") }
        },
        value: {
          typecast: :nonempty_str,
          placeholder: "JSON",
          required: nil
        }
      }) do |obj, name, value|
        begin
          value = JSON.parse(value) if value
        rescue JSON::ParserError
          fail CloverError.new(400, "InvalidRequest", "invalid JSON for feature flag value")
        end
        obj.send("set_ff_#{name}", value)
      end,
      "set_quota" => object_action("Set Quota", "Set quota", {
        resource_type: {
          typecast: :str!,
          type: "select",
          add_blank: true,
          options: ProjectQuota.default_quotas.keys
        },
        value: {
          typecast: :int,
          type: "number",
          placeholder: "blank to reset to default",
          required: nil
        }
      }) do |obj, resource_type, value|
        quota_id = ProjectQuota.default_quotas[resource_type]["id"]
        if (existing_quota = obj.quotas_dataset.first(quota_id:))
          if value
            existing_quota.update(value:)
          else
            existing_quota.destroy
          end
        elsif value
          obj.add_quota(quota_id:, value:)
        end
      end
    },
    "Strand" => {
      "schedule" => object_action("Schedule Strand to Run Immediately", "Scheduled strand to run immediately") do |obj|
        obj.this.update(schedule: Sequel::CURRENT_TIMESTAMP)
      end,
      "extend" => object_action("Extend Schedule", "Extended schedule", {minutes: :pos_int!}) do |obj, minutes|
        obj.this.update(schedule: Sequel.date_add(:schedule, minutes:))
      end
    },
    "Vm" => {
      "restart" => object_action("Restart", "Restart scheduled for Vm", &:incr_restart),
      "stop" => object_action("Stop", "Stop scheduled for Vm") do |obj|
        DB.transaction do
          obj.incr_admin_stop
          obj.incr_stop
        end
      end
    },
    "VmHost" => {
      "accept" => object_action("Move to Accepting", "Host allocation state changed to accepting") do |obj|
        obj.update(allocation_state: "accepting")
      end,
      "drain" => object_action("Move to Draining", "Host allocation state changed to draining") do |obj|
        obj.update(allocation_state: "draining")
      end,
      "reset" => object_action("Hardware Reset", "Hardware reset scheduled for VmHost", &:incr_hardware_reset),
      "reboot" => object_action("Reboot", "Reboot scheduled for VmHost", &:incr_reboot)
    }
  }.freeze
  OBJECT_ACTIONS.each_value(&:freeze)

  OBJECTS_WITH_EXTRAS = Dir["views/admin/extras/*.erb"]
    .map { File.basename(it, ".erb") }
    .each_with_object({}) { |name, h| h[name] = true }
    .freeze

  OBJECT_ASSOC_TABLE_PARAMS = {
    ["GithubInstallation", :runners] => "installation",
    ["Project", :vms] => "project",
    ["Project", :postgres_resources] => "project",
    ["PostgresResource", :servers] => "resource"
  }.freeze

  plugin :autoforme do
    # :nocov:
    register_by_name if Config.development?
    # :nocov:

    pagination_strategy :filter
    order [:id]
    supported_actions [:browse, :search]
    form_options(wrapper: :div)

    link = lambda do |obj, label: "admin_label"|
      return "" unless obj

      "<a href=\"/model/#{obj.class}/#{obj.ubid}\">#{Erubi.h(obj.send(label))}</a>"
    end

    show_html do |obj, column|
      case column
      when :name, :ubid, :invoice_number
        link.call(obj, label: column)
      when :project, :location, :vm_host, :billing_info, :resource, :parent
        link.call(obj.send(column))
      when :vm
        link.call(obj.send(column), label: :ubid)
      when :subtotal, :cost
        "$%0.02f" % (obj.send(column) || 0)
      end
    end

    column_grep = lambda do |ds, column, value|
      ds.where(Sequel.cast(column, :text).ilike("%#{ds.escape_like(value)}%"))
    end

    ubid_uuid_grep = lambda do |ds, column, value|
      uuid = if UBID_REGEXP.match?(value)
        UBID.to_uuid(value)
      elsif UUID_REGEXP.match?(value)
        value
      end
      ds.where(column => uuid)
    end

    ubid_input = lambda do |name|
      {type: "text", placeholder: "#{name} UBID/UUID", maxlength: 36, minlength: 26}
    end

    model Firewall do
      eager [:project, :location]
      columns [:name, :project, :location, :description]
    end

    model Account do
      order Sequel.desc(Sequel[:accounts][:created_at])
      eager_graph [:identities]
      columns [:name, :email, :status_id, :provider_names, :created_at, :suspended_at]
      column_options email: {type: "text"},
        status_id: {type: "select", options: {Unverified: 1, Verified: 2, Closed: 3}, add_blank: true},
        provider_names: {label: "Providers", type: "select", options: ["google", "github"], add_blank: true},
        created_at: {type: "text"},
        suspended_at: {label: "Suspended", type: "boolean", value: nil}

      column_search_filter do |ds, column, value|
        case column
        when :provider_names
          ds.where(provider: value)
        when :created_at
          column_grep.call(ds, Sequel[:accounts][:created_at], value)
        when :suspended_at
          ds.send((value == "t") ? :exclude : :where, suspended_at: nil)
        end
      end
    end

    model BillingInfo do
      order Sequel.desc(:created_at)
      eager_graph [:project]
      columns do |type_symbol, request|
        cs = [:stripe_id, :project, :valid_vat, :created_at]
        cs.prepend(:ubid) unless type_symbol == :search_form
        cs
      end
      column_options project: ubid_input.call("Project"),
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :project
          ubid_uuid_grep.call(ds, Sequel[:project][:id], value)
        when :created_at
          column_grep.call(ds, Sequel[:billing_info][:created_at], value)
        end
      end
    end

    model GithubInstallation do
      order Sequel.desc(:created_at)
      columns [:name, :installation_id, :type, :cache_enabled, :premium_runner_enabled?, :created_at, :allocator_preferences]

      column_options type: {type: "select", options: ["Organization", "User"], add_blank: true},
        premium_runner_enabled?: {label: "Premium enabled", type: "boolean", value: nil},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :premium_runner_enabled?
          family_filter = Sequel.pg_jsonb(:allocator_preferences).get("family_filter")
          cond = family_filter.contains(["premium"])
          if value == "t"
            ds.where(cond)
          else
            ds.where(~cond | {family_filter => nil})
          end
        when :allocator_preferences, :created_at
          column_grep.call(ds, column, value)
        end
      end
    end

    model GithubRunner do
      order Sequel.desc(:created_at)
      eager_graph [:strand]
      eager [:installation]
      columns do |type_symbol, request|
        cs = [:repository_name, :label, :strand_label, :created_at]
        cs.prepend(:installation) if type_symbol == :search_form
        cs.prepend(:ubid) unless type_symbol == :search_form
        cs
      end

      column_options strand_label: {type: "text"},
        created_at: {type: "text"},
        installation: ubid_input.call("Installation")

      column_search_filter do |ds, column, value|
        case column
        when :strand_label
          column_grep.call(ds, Sequel[:strand][:label], value)
        when :created_at
          column_grep.call(ds, column, value)
        when :installation
          ubid_uuid_grep.call(ds, :installation_id, value)
        end
      end
    end

    model Invoice do
      order Sequel.desc(:invoice_number)
      eager_graph [:project]
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:invoice_number, :project, :status]
        else
          [:invoice_number, :project, :status, :subtotal, :cost]
        end
      end
      column_options status: {type: "select", options: %w[unpaid paid fraud waiting_transfer below_minimum_threshold], add_blank: true},
        project: ubid_input.call("Project")

      column_search_filter do |ds, column, value|
        case column
        when :project
          ubid_uuid_grep.call(ds, Sequel[:project][:id], value)
        end
      end
    end

    model PaymentMethod do
      order Sequel.desc(:created_at)
      eager [:billing_info]
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:stripe_id, :fraud, :created_at]
        else
          [:ubid, :stripe_id, :billing_info, :fraud, :created_at]
        end
      end
      column_options fraud: {type: "boolean", value: nil},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :fraud
          ds.where(fraud: value == "t")
        when :created_at
          column_grep.call(ds, column, value)
        end
      end
    end

    model PostgresResource do
      order Sequel.desc(:created_at)
      eager do |type, _request|
        [:location, :parent, :project] unless type == :association
      end
      columns [:name, :project, :location, :flavor, :target_vm_size, :target_storage_size_gib, :ha_type, :target_version, :parent, :created_at]
      column_options flavor: {type: "select", options: %w[standard paradedb lantern], add_blank: true},
        ha_type: {type: "select", options: %w[none async sync], add_blank: true},
        target_version: {type: "select", options: Option::POSTGRES_VERSION_OPTIONS[PostgresResource::Flavor::STANDARD], add_blank: true},
        target_storage_size_gib: {type: "number"},
        project: ubid_input.call("Project"),
        parent: ubid_input.call("Parent"),
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :project, :parent
          ubid_uuid_grep.call(ds, :"#{column}_id", value)
        when :created_at
          column_grep.call(ds, :created_at, value)
        end
      end
    end

    model PostgresServer do
      order Sequel.desc(:created_at)
      eager [:resource, :vm]
      columns do |type_symbol, request|
        cs = [:resource, :timeline_access, :synchronization_status, :version, :is_representative, :created_at]
        unless type_symbol == :search_form
          cs.prepend(:vm)
          cs.prepend(:ubid)
        end
        cs
      end
      column_options resource: ubid_input.call("Resource"),
        timeline_access: {type: "select", options: %w[push fetch], add_blank: true},
        synchronization_status: {type: "select", options: %w[ready catching_up], add_blank: true},
        version: {type: "select", options: Option::POSTGRES_VERSION_OPTIONS[PostgresResource::Flavor::STANDARD], add_blank: true},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :resource
          ubid_uuid_grep.call(ds, :resource_id, value)
        when :created_at
          column_grep.call(ds, column, value)
        end
      end
    end

    model Project do
      order Sequel.desc(:created_at)
      columns [:name, :reputation, :billing_info_id, :credit, :created_at]
      column_options reputation: {type: "select", options: %w[new verified limited], add_blank: true},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :created_at
          column_grep.call(ds, column, value)
        end
      end
    end

    model Strand do
      order Sequel.desc(:try)
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:prog, :label, :try]
        else
          [:ubid, :prog, :label, :schedule, :try]
        end
      end
      column_options try: {type: "number", value: nil}
    end

    model Vm do
      order Sequel.desc(:created_at)
      eager do |type, _request|
        [:location, :vm_host, :project] unless type == :association
      end
      columns [:name, :display_state, :project, :vm_host, :location, :arch, :boot_image, :family, :vcpus, :created_at]
      column_options display_state: {type: "select", options: ["running", "creating", "starting", "rebooting", "deleting"], add_blank: true},
        arch: {type: "select", options: ["x64", "arm64"], add_blank: true},
        family: {type: "select", options: Option::VmFamilies.map(&:name), add_blank: true},
        vcpus: {type: "number"},
        created_at: {type: "text"},
        project: ubid_input.call("Project")

      column_search_filter do |ds, column, value|
        case column
        when :created_at
          column_grep.call(ds, :created_at, value)
        when :project
          ubid_uuid_grep.call(ds, :project_id, value)
        end
      end
    end

    model VmHost do
      order Sequel[:vm_host][:id]
      eager [:location]
      eager_graph [:sshable]
      columns do |type_symbol, request|
        cs = [:sshable_host, :allocation_state, :arch, :location, :data_center, :family, :total_cores, :total_hugepages_1g]
        cs.prepend(:ubid) unless type_symbol == :search_form
        cs
      end
      column_options sshable_host: {label: "Sshable", type: :text, value: ""},
        allocation_state: {type: "select", options: ["accepting", "draining", "unprepared"], add_blank: true},
        arch: {type: "select", options: ["x64", "arm64"], add_blank: true},
        family: {type: "select", options: Option::VmFamilies.map(&:name), add_blank: true},
        total_cores: {type: "number"},
        total_hugepages_1g: {type: "number"}

      column_search_filter do |ds, column, value|
        if column == :sshable_host
          column_grep.call(ds, Sequel[:sshable][:host], value)
        end
      end
    end
  end

  route do |r|
    r.public
    check_csrf!
    r.rodauth
    rodauth.require_authentication

    # :nocov:
    rodauth.require_two_factor_setup unless skip_webauthn_requirement
    r.exception_page_assets if Config.development?
    # :nocov:

    r.on "model", /([A-Z][a-zA-Z]+)/ do |model_name|
      begin
        @klass = Object.const_get(model_name)
      rescue NameError
        next
      end

      next unless @klass.is_a?(Class) && @klass < ResourceMethods::InstanceMethods

      r.get true do
        limit = 101
        ds = @klass.limit(limit).order(:id)

        if (after = typecast_params.ubid_uuid("after"))
          ds = ds.where { id > after }
        end

        @objects = ds.all

        if @objects.length == limit
          @objects.pop
          @after = @objects.last.ubid
        end

        view("objects")
      end

      r.on :ubid do |ubid|
        next unless (@obj = @klass[ubid])

        r.get true do
          view("object")
        end

        if (actions = OBJECT_ACTIONS[@obj.class.name])
          r.is actions.keys do |key|
            action = actions[key]

            r.get do
              @label = action.label
              @params = action.params
              view("object_action")
            end

            r.post do
              params = action.params.map { |k, v| typecast_params.send(v.is_a?(Hash) ? v[:typecast] : v, k.to_s) }
              action.call(@obj, *params)
              flash["notice"] = action.flash
              r.redirect("/model/#{@obj.class}/#{ubid}")
            end
          end
        end
      end
    end

    r.on "autoforme" do
      autoforme
    end

    r.get "archived-record-by-id" do
      @id = if (uuid = typecast_params.uuid("id"))
        UBID.from_uuidish(uuid)
      elsif (ubid = typecast_params.ubid("id"))
        begin
          UBID.parse(ubid)
        rescue UBIDParseError
          fail CloverError.new(400, "InvalidRequest", "Invalid UBID provided")
        end
      elsif typecast_params.nonempty_str("id")
        fail CloverError.new(400, "InvalidRequest", "Invalid UBID or UUID provided")
      end
      @model_name = typecast_params.nonempty_str("model_name") || UBID.class_for_ubid(@id.to_s)&.name
      @days = (typecast_params.pos_int("days") || 5).clamp(1, 15)
      @classes = available_classes
      @record = if @id
        fail CloverError.new(400, "InvalidRequest", "Could not determine model name from ID") unless @model_name
        ArchivedRecord.find_by_id(@id.to_uuid, model_name: @model_name, days: @days)
      end

      view("archived_record_by_id")
    end

    r.get "vm-by-ipv4" do
      if (@ips_param = typecast_params.nonempty_str("ips"))
        ips = @ips_param.split(",").filter_map {
          begin
            NetAddr.parse_net(it.strip).to_s
          rescue
            nil
          end
        }

        active_vms = Vm.from_ips(ips).map {
          {
            ip: it.assigned_vm_address.ip.to_s,
            created_at: it.created_at,
            archived_at: nil,
            vm_id: it.ubid,
            vm_name: it.name,
            boot_image: it.boot_image,
            project_id: it.project.ubid
          }
        }
        archived_vms = ArchivedRecord.vms_by_ips(ips).map {
          {
            ip: it[:ip],
            created_at: it[:created_at],
            archived_at: it[:archived_at],
            vm_id: UBID.from_uuidish(it[:vm_id]).to_s,
            vm_name: it[:vm_name],
            boot_image: it[:boot_image],
            project_id: UBID.from_uuidish(it[:project_id]).to_s
          }
        }
        @vms = (active_vms + archived_vms).sort_by { [it[:ip], -it[:created_at].to_i] }
      end

      view("vm_by_ipv4")
    end

    r.root do
      if (ubid = typecast_params.ubid("id")) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif (uuid = typecast_params.uuid("id")) && (ubid = UBID.from_uuidish(uuid).to_s) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif typecast_params.nonempty_str("id")
        flash.now["error"] = "Invalid ubid/uuid provided"
      end

      @grouped_pages = Page.active.reverse(:created_at, :summary).exclude(severity: "info").group_by_vm_host
      @classes = available_classes
      @info_pages = Page.where(severity: "info").reverse(:created_at).all

      view("index")
    end

    # :nocov:
    if Config.test?
      # :nocov:
      r.get("error") { raise }
    end
  end
end
