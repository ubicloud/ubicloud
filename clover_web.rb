# frozen_string_literal: true

require "tilt/sass"

class CloverWeb < Roda
  include CloverBase

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
    csp.img_src :self, "data: image/svg+xml"
    csp.form_action :self, "https://checkout.stripe.com"
    csp.script_src :self, "https://cdn.jsdelivr.net/npm/jquery@3.7.0/dist/jquery.min.js", "https://cdn.jsdelivr.net/npm/dompurify@3.0.5/dist/purify.min.js"
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
  plugin :h

  plugin :not_found do
    @error = {
      code: 404,
      title: "Resource not found",
      message: "Sorry, we couldn’t find the resource you’re looking for."
    }

    view "/error"
  end

  if Config.development?
    # :nocov:
    plugin :exception_page
    class RodaRequest
      def assets
        exception_page_assets
        super
      end
    end
    # :nocov:
  end

  plugin :error_handler do |e|
    @error = parse_error(e)

    case e
    when Sequel::ValidationFailed
      flash["error"] = @error[:message]
      return redirect_back_with_inputs
    when Validation::ValidationFailed
      flash["errors"] = (flash["errors"] || {}).merge(@error[:details])
      return redirect_back_with_inputs
    when Roda::RodaPlugins::RouteCsrf::InvalidToken
      flash["error"] = "An invalid security token submitted with this request, please try again"
      return redirect_back_with_inputs
    end

    # :nocov:
    next exception_page(e, assets: true) if Config.development? && @error[:code] == 500
    # :nocov:

    view "/error"
  end

  plugin :sessions,
    key: "_Clover.session",
    cookie_options: {secure: !(Config.development? || Config.test?)},
    secret: Config.clover_session_secret

  autoload_routes("web")

  plugin :rodauth do
    enable :argon2, :change_login, :change_password, :close_account, :create_account,
      :lockout, :login, :logout, :remember, :reset_password,
      :otp, :recovery_codes, :sms_codes,
      :disallow_password_reuse, :password_grace_period, :active_sessions,
      :verify_login_change, :change_password_notify, :confirm_password
    title_instance_variable :@page_title

    # :nocov:
    unless Config.development?
      enable :disallow_common_passwords, :verify_account

      email_from Config.mail_from

      verify_account_view { view "auth/verify_account", "Verify Account" }
      resend_verify_account_view { view "auth/verify_account_resend", "Resend Verification" }
      verify_account_email_sent_redirect { login_route }
      verify_account_email_recently_sent_redirect { login_route }
      verify_account_set_password? false

      send_verify_account_email do
        scope.send_email(email_to, "Welcome to Ubicloud: Please Verify Your Account",
          greeting: "Welcome to Ubicloud,",
          body: ["To complete your registration and activate your account, click the button below.",
            "If you did not initiate this registration process, you may disregard this message.",
            "We're excited to serve you. Should you require any assistance, our customer support team stands ready to help at support@ubicloud.com."],
          button_title: "Verify Account",
          button_link: verify_account_email_link)
      end
    end
    # :nocov:

    hmac_secret Config.clover_session_secret

    login_view { view "auth/login", "Login" }
    login_redirect { "/after-login" }
    login_return_to_requested_location? true
    two_factor_auth_return_to_requested_location? true
    already_logged_in { redirect login_redirect }
    after_login { remember_login if request.params["remember-me"] == "on" }

    create_account_view { view "auth/create_account", "Create Account" }
    create_account_redirect { login_route }
    create_account_set_password? true
    before_create_account do
      account[:id] = Account.generate_uuid
      account[:name] = param("name")
    end
    after_create_account do
      Account[account_id].create_project_with_default_policy("Default")
    end

    reset_password_view { view "auth/reset_password", "Request Password" }
    reset_password_request_view { view "auth/reset_password_request", "Request Password Reset" }
    reset_password_redirect { login_route }
    reset_password_email_sent_redirect { login_route }
    reset_password_email_recently_sent_redirect { reset_password_request_route }

    send_reset_password_email do
      user = Account[account_id]
      scope.send_email(user.email, "Reset Ubicloud Account Password",
        greeting: "Hello #{user.name},",
        body: ["We received a request to reset your account password. To reset your password, click the button below.",
          "If you did not initiate this request, no action is needed. Your account remains secure.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."],
        button_title: "Reset Password",
        button_link: reset_password_email_link)
    end

    change_password_redirect "/account/change-password"
    change_password_route "account/change-password"
    change_password_view { view "account/change_password", "My Account" }

    change_login_redirect "/account/change-login"
    change_login_route "account/change-login"
    change_login_view { view "account/change_login", "My Account" }

    verify_login_change_view { view "auth/verify_login_change", "Verify Email Change" }
    send_verify_login_change_email do |new_login|
      user = Account[account_id]
      scope.send_email(email_to, "Please Verify New Email Address for Ubicloud",
        greeting: "Hello #{user.name},",
        body: ["We received a request to change your account email to '#{new_login}'. To verify new email, click the button below.",
          "If you did not initiate this request, no action is needed. Current email address can be used to login your account.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."],
        button_title: "Verify Email",
        button_link: verify_login_change_email_link)
    end

    close_account_redirect "/login"
    close_account_route "account/close-account"
    close_account_view { view "account/close_account", "My Account" }

    argon2_secret { Config.clover_session_secret }
    require_bcrypt? false
  end

  def redirect_back_with_inputs
    flash["old"] = request.params
    request.redirect env["HTTP_REFERER"]
  end

  hash_branch("dashboard") do |r|
    view "/dashboard"
  end

  hash_branch("after-login") do |r|
    r.redirect "#{@current_user.projects.first.path}/dashboard"
  end

  route do |r|
    r.public
    r.assets

    r.on "webhook" do
      r.hash_branches(:webhook_prefix)
    end
    check_csrf!

    rodauth.load_memory
    rodauth.check_active_session
    @current_user = Account[rodauth.session_value]
    r.rodauth
    r.root do
      r.redirect rodauth.login_route
    end
    rodauth.require_authentication

    r.hash_branches("")
  end
end
