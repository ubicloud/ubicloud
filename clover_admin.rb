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
    handle_type(:ubid) do
      it if /\A[a-tv-z0-9]{26}\z/.match?(it)
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

  plugin :forme_route_csrf
  Forme.register_config(:clover_admin, base: :default, labeler: :explicit)
  Forme.default_config = :clover_admin

  def self.create_admin_account(login, password = SecureRandom.urlsafe_base64(16))
    password_hash = rodauth.new(nil).password_hash(password)
    DB.transaction do
      id = DB[:admin_account].insert(login:)
      DB[:admin_password_hash].insert(id:, password_hash:)
    end
    password
  end

  plugin :rodauth, route_csrf: true do
    enable :argon2, :login, :logout, :webauthn, :change_password
    accounts_table :admin_account
    password_hash_table :admin_password_hash
    webauthn_keys_table :admin_webauthn_key
    webauthn_user_ids_table :admin_webauthn_user_id
    login_column :login
    require_bcrypt? false
    title_instance_variable :@page_title
    argon2_secret OpenSSL::HMAC.digest("SHA256", Config.clover_session_secret, "admin-argon2-secret")
    hmac_secret OpenSSL::HMAC.digest("SHA512", Config.clover_session_secret, "admin-rodauth-hmac-secret")
    function_name(&{
      rodauth_get_salt: :rodauth_admin_get_salt,
      rodauth_valid_password_hash: :rodauth_admin_valid_password_hash
    }.to_proc)
  end

  route do |r|
    r.public
    r.rodauth
    rodauth.require_authentication
    rodauth.require_two_factor_setup

    # :nocov:
    r.exception_page_assets if Config.development?
    # :nocov:

    r.get "model", /([A-Z][a-zA-Z]+)/, :ubid do |model_name, ubid|
      begin
        @klass = Object.const_get(model_name)
      rescue NameError
        next
      end

      next unless @klass.is_a?(Class) && @klass < ResourceMethods::InstanceMethods
      next unless (@obj = @klass[ubid])

      view("object")
    end

    r.root do
      if (ubid = typecast_params.ubid("ubid")) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif typecast_params.nonempty_str("ubid")
        flash.now["error"] = "Invalid ubid provided"
      end

      view("index")
    end
  end
end
