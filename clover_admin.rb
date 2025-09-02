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

    handle_type(:ubid) do
      it if ubid_regexp.match?(it)
    end

    handle_type(:ubid_uuid) do
      UBID.to_uuid(it) if ubid_regexp.match?(it)
    end
  end

  plugin :symbol_matchers
  symbol_matcher(:ubid, /([a-tv-z0-9]{26})/)

  plugin :not_found do
    @page_title = "File Not Found"
    view(content: "")
  end

  plugin :route_csrf do |token|
    flash.now["error"] = "An invalid security token submitted with this request, please try again"
    @page_title = "Invalid Security Token"
    view(content: "")
  end

  plugin :error_handler do |e|
    raise e if Config.test? && ENV["SHOW_ERRORS"]
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

  route do |r|
    r.public
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

      r.get :ubid do |ubid|
        next unless (@obj = @klass[ubid])

        view("object")
      end
    end

    r.root do
      if (ubid = typecast_params.ubid("ubid")) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif typecast_params.nonempty_str("ubid")
        flash.now["error"] = "Invalid ubid provided"
      end

      @grouped_pages = Page.active.reverse(:created_at, :summary).group_by_vm_host
      @classes = Sequel::Model
        .subclasses
        .map { [it, it.subclasses] }
        .flatten
        .select { it < ResourceMethods::InstanceMethods }
        .sort_by(&:name)

      view("index")
    end

    # :nocov:
    if Config.test?
      # :nocov:
      r.get("error") { raise }
    end
  end
end
