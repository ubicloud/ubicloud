# frozen_string_literal: true

require_relative "model"

require "mail"
require "roda"
require "tilt/sass"

class Clover < Roda
  opts[:check_dynamic_arity] = false
  opts[:check_arity] = :warn

  plugin :default_headers,
    "Content-Type" => "text/html",
    # 'Strict-Transport-Security'=>'max-age=16070400;', # Uncomment if only allowing https:// access
    "X-Frame-Options" => "deny",
    "X-Content-Type-Options" => "nosniff",
    "X-XSS-Protection" => "1; mode=block"

  plugin :content_security_policy do |csp|
    csp.default_src :none
    csp.style_src :self
    csp.img_src :self
    csp.form_action :self
    csp.script_src :self, "https://cdn.jsdelivr.net"
    csp.connect_src :self
    csp.base_uri :none
    csp.frame_ancestors :none
  end

  plugin :route_csrf
  plugin :disallow_file_uploads
  plugin :flash
  plugin :assets, js: "app.js", css: "app.css", css_opts: {style: :compressed, cache: false}, timestamp_paths: true
  plugin :render, escape: true, layout: "./layouts/app"
  plugin :public
  plugin :Integer_matcher_max
  plugin :typecast_params_sized_integers, sizes: [64], default_size: 64
  plugin :hash_branch_view_subdir
  plugin :all_verbs
  plugin :request_headers

  logger = if ENV["RACK_ENV"] == "test"
    Class.new {
      def write(_)
      end
    }.new
  else
    $stderr
  end
  plugin :common_logger, logger

  plugin :not_found do
    @error_code = 404
    @error_title = "Page not found"
    @error_detail = "Sorry, we couldn’t find the page you’re looking for."

    view "/error"
  end

  case Config.mail_driver
  when :smtp
    ::Mail.defaults do
      delivery_method :smtp, {
        address: Config.smtp_hostname,
        port: Config.smtp_port,
        user_name: Config.smtp_user,
        password: Config.smtp_password,
        authentication: :plain,
        enable_starttls: Config.smtp_tls
      }
    end
  when :logger
    ::Mail.defaults do
      delivery_method :logger
    end
  when :test
    ::Mail.defaults do
      delivery_method :test
    end
  end

  if Config.development?
    plugin :exception_page
    class RodaRequest
      def assets
        exception_page_assets
        super
      end
    end
  else
    def self.freeze
      Sequel::Model.freeze_descendents unless Config.test?
      DB.freeze
      super
    end
  end

  plugin :error_handler do |e|
    case e
    when Sequel::ValidationFailed
      flash["error"] = e.to_s
      return redirect_back_with_inputs
    when Validation::ValidationFailed
      flash["errors"] = (flash["errors"] || {}).merge(e.errors)
      return redirect_back_with_inputs
    when Roda::RodaPlugins::RouteCsrf::InvalidToken
      response.status = 419
      @error_code = 419
      @error_title = "Invalid Security Token"
      @error_detail = "An invalid security token was submitted with this request, and this request could not be processed."
    when Authorization::Unauthorized
      response.status = 403
      @error_code = 403
      @error_title = "Forbidden"
      @error_detail = "Sorry, you don't have permission to continue with this request."
    else
      $stderr.print "#{e.class}: #{e.message}\n"
      warn e.backtrace
      next exception_page(e, assets: true) if ENV["RACK_ENV"] == "development"

      @error_code = 500
      @error_title = "Unexcepted Error"
      @error_detail = "Sorry, we couldn’t process your request because of an unexpected error."
    end

    if request.headers["Accept"] == "application/json"
      response["Content-Type"] = "application/json"
      return {
        error_code: @error_code,
        error_title: @error_title,
        error_detail: @error_detail
      }.to_json
    end

    view "/error"
  end

  plugin :sessions,
    key: "_Clover.session",
    cookie_options: {secure: !%w[test development].include?(ENV["RACK_ENV"])},
    secret: Config.clover_session_secret

  autoload_normal("serializers/web", include_first: true)

  # YYY: It'd be nice to use autoload, but it can't work while
  # constants used across files are defined inside routes files and
  # the autoload dependency cannot be tracked cheaply.
  #
  # if Unreloader.autoload?
  #   plugin :autoload_hash_branches
  #   autoload_hash_branch_dir("./routes")
  # end

  Unreloader.require("routes", delete_hook: proc { |f| hash_branch(File.basename(f).delete_suffix(".rb")) }) {}

  plugin :rodauth do
    enable :argon2, :change_login, :change_password, :close_account, :create_account,
      :lockout, :login, :logout, :remember, :reset_password,
      :otp, :recovery_codes, :sms_codes,
      :disallow_password_reuse, :password_grace_period, :active_sessions,
      :verify_login_change, :change_password_notify, :confirm_password
    title_instance_variable :@page_title

    unless Config.development?
      enable :disallow_common_passwords, :verify_account

      email_from Config.mail_from

      verify_account_view { view "auth/verify_account", "Verify Account" }
      resend_verify_account_view { view "auth/verify_account_resend", "Resend Verification" }
      verify_account_email_sent_redirect { login_route }
      verify_account_email_recently_sent_redirect { login_route }
      verify_account_set_password? false
    end

    hmac_secret Config.clover_session_secret

    login_view { view "auth/login", "Login" }
    login_redirect "/dashboard"
    login_return_to_requested_location? true
    two_factor_auth_return_to_requested_location? true
    already_logged_in { redirect login_redirect }
    after_login { remember_login if request.params["remember-me"] == "on" }

    create_account_view { view "auth/create_account", "Create Account" }
    create_account_redirect { login_route }
    create_account_set_password? true
    after_create_account do
      current_user = Account[account_id]
      current_user.create_tag_space_with_default_policy("#{current_user.username}_default_tag_space")
    end

    reset_password_view { view "auth/reset_password", "Request Password" }
    reset_password_request_view { view "auth/reset_password_request", "Request Password Reset" }
    reset_password_redirect { login_route }
    reset_password_email_sent_redirect { login_route }
    reset_password_email_recently_sent_redirect { reset_password_request_route }

    change_password_redirect "/settings/change-password"
    change_password_route "settings/change-password"
    change_password_view { view "settings/change_password", "Settings" }

    change_login_redirect "/settings/change-login"
    change_login_route "settings/change-login"
    change_login_view { view "settings/change_login", "Settings" }

    close_account_redirect "/login"
    close_account_route "settings/close-account"
    close_account_view { view "settings/close_account", "Settings" }

    # YYY: Should password secret and session secret be the same? Are
    # there rotation issues? See also:
    #
    # https://github.com/jeremyevans/rodauth/commit/6cbf61090a355a20ab92e3420d5e17ec702f3328
    # https://github.com/jeremyevans/rodauth/commit/d8568a325749c643c9a5c9d6d780e287f8c59c31
    argon2_secret { Config.clover_session_secret }
    require_bcrypt? false
  end

  def redirect_back_with_inputs
    flash["old"] = request.params
    request.redirect env["HTTP_REFERER"]
  end

  def vm_host_allowed?
    vm_host_users = Config.allowed_vm_host_users
    return true if vm_host_users.empty?
    vm_host_users.include?(Account[rodauth.session_value].email)
  end

  def serialize(data, structure = :default)
    @serializer.new(structure).serialize(data)
  end

  hash_branch("dashboard") do |r|
    view "/dashboard"
  end

  route do |r|
    check_csrf! unless r.env["CONTENT_TYPE"]&.include?("application/json")

    r.public
    r.assets

    rodauth.load_memory
    rodauth.check_active_session
    r.rodauth
    r.root do
      r.redirect rodauth.login_route
    end
    rodauth.require_authentication
    check_csrf!

    r.hash_branches
  end
end
