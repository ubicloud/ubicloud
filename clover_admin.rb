# frozen_string_literal: true

require_relative "model"

require "roda"
require "tilt"
require "tilt/erubi"
require "openssl"

class CloverAdmin < Roda
  # :nocov:
  plugin :exception_page if Config.development?
  default_fixed_locals = if Config.production? || ENV["CLOVER_FREEZE"] == "1"
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

  plugin :typecast_params_sized_integers, sizes: [64], default_size: 64
  plugin :typecast_params do
    ubid_regexp = /\A[a-tv-z0-9]{26}\z/
    uuid_regexp = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/i

    handle_type(:ubid) do
      it if ubid_regexp.match?(it)
    end

    handle_type(:uuid) do
      it if uuid_regexp.match?(it)
    end

    handle_type(:ubid_uuid) do
      UBID.to_uuid(it) if ubid_regexp.match?(it)
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

    Clog.emit("admin route exception") { Util.exception_to_hash(e) }
    @page_title = "Internal Server Error"
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
    Clog.emit("Created admin account") { {admin_account_created: login} }
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

  plugin :rodauth, route_csrf: true do
    enable :argon2, :login, :logout, :webauthn, :change_password
    accounts_table :admin_account
    password_hash_table :admin_password_hash
    webauthn_keys_table :admin_webauthn_key
    webauthn_user_ids_table :admin_webauthn_user_id
    login_column :login
    login_redirect do
      uses_two_factor_authentication? ? "/webauthn-auth" : "/webauthn-setup"
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
      end
    },
    "Strand" => {
      "schedule" => object_action("Schedule Strand to Run Immediately", "Scheduled strand to run immediately") do |obj|
        obj.this.update(schedule: Sequel::CURRENT_TIMESTAMP)
      end
    },
    "Vm" => {
      "restart" => object_action("Restart", "Restart scheduled for Vm", &:incr_restart)
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

  plugin :autoforme do
    # :nocov:
    register_by_name if Config.development?
    # :nocov:

    pagination_strategy :filter
    order [:id]
    supported_actions [:browse, :search]
    form_options(wrapper: :div)

    link = lambda do |obj|
      return "" unless obj

      "<a href=\"/model/#{obj.class}/#{obj.ubid}\">#{Erubi.h(obj.name)}</a>"
    end

    show_html do |obj, column|
      case column
      when :name
        link.call(obj)
      when :project, :location, :vm_host
        link.call(obj.send(column))
      end
    end

    column_grep = lambda do |ds, column, value|
      ds.where(Sequel.cast(column, :text).ilike("%#{ds.escape_like(value)}%"))
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

    model Strand do
      order Sequel.desc(:try)
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:prog, :label, :try]
        else
          [:name, :prog, :label, :schedule, :try]
        end
      end
      column_options try: {type: "number", value: nil}
    end

    model Vm do
      order Sequel.desc(:created_at)
      eager [:location, :vm_host]
      columns [:name, :display_state, :vm_host, :location, :arch, :boot_image, :family, :vcpus, :created_at]
      column_options display_state: {type: "select", options: ["running", "creating", "starting", "rebooting", "deleting"], add_blank: true},
        arch: {type: "select", options: ["x64", "arm64"], add_blank: true},
        family: {type: "select", options: Option::VmFamilies.map(&:name), add_blank: true},
        vcpus: {type: "number"},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        if column == :created_at
          column_grep.call(ds, column, value)
        end
      end
    end

    model VmHost do
      order Sequel[:vm_host][:id]
      eager [:location]
      eager_graph [:sshable]
      columns do |type_symbol, request|
        cs = [:sshable_host, :allocation_state, :arch, :location, :data_center, :family, :total_cores, :total_hugepages_1g]
        cs.prepend(:name) unless type_symbol == :search_form
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
    rodauth.require_two_factor_setup

    # :nocov:
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
              params = action.params.map { |k, v| typecast_params.send(v, k.to_s) }
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

    r.root do
      if (ubid = typecast_params.ubid("id")) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif (uuid = typecast_params.uuid("id")) && (ubid = UBID.from_uuidish(uuid).to_s) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif typecast_params.nonempty_str("id")
        flash.now["error"] = "Invalid ubid/uuid provided"
      end

      @grouped_pages = Page.active.reverse(:created_at, :summary).group_by_vm_host
      @classes = Sequel::Model
        .subclasses
        .map { [it, it.subclasses] }
        .flatten
        .select { it < ResourceMethods::InstanceMethods }
        .sort_by(&:name)
      @annotations = Annotation.order(Sequel.desc(:created_at)).all

      view("index")
    end

    # :nocov:
    if Config.test?
      # :nocov:
      r.get("error") { raise }
    end
  end
end
