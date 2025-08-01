# frozen_string_literal: true

require_relative "model"

require "committee"
require "roda"
require "tilt"
require "tilt/erubi"

class Clover < Roda
  # :nocov:
  linting = Config.test? && !defined?(SimpleCov)
  use Rack::Lint if linting
  if linting || Config.development? # Assume Rack::Lint added automatically in development
    require "rack/rewindable_input"
    use Rack::RewindableInput::Middleware
  end
  # :nocov:

  OPENAPI = OpenAPIParser.load("openapi/openapi.yml", strict_reference_validation: true)
  SCHEMA = Committee::Drivers::OpenAPI3::Driver.new.parse(OPENAPI)
  SCHEMA_ROUTER = SCHEMA.build_router(schema: SCHEMA, strict: true)

  opts[:check_dynamic_arity] = false
  opts[:check_arity] = :warn

  Unreloader.require("helpers") {}
  Unreloader.record_split_class(__FILE__, "helpers")

  # :nocov:
  default_fixed_locals = if Config.production? || ENV["CLOVER_FREEZE"] == "1"
    "()"
  # :nocov:
  else
    "(_no_kw: nil)"
  end

  plugin :all_verbs
  plugin :assets, js: "app.js", css: "app.css", css_opts: {style: :compressed, cache: false}, timestamp_paths: true
  plugin :disallow_file_uploads
  plugin :flash
  plugin :h
  plugin :hash_branches
  plugin :hooks
  plugin :Integer_matcher_max
  plugin :json
  plugin :invalid_request_body, :raise
  plugin :json_parser, wrap: :unless_hash, error_handler: lambda { |r| raise Roda::RodaPlugins::InvalidRequestBody::Error, "invalid JSON uploaded" }
  plugin :public
  plugin :render, escape: true, layout: "./layouts/app", template_opts: {chain_appends: !defined?(SimpleCov), freeze: true, skip_compiled_encoding_detection: true, scope_class: self, default_fixed_locals:, extract_fixed_locals: true}, assume_fixed_locals: true
  plugin :part
  plugin :request_headers
  plugin :plain_hash_response_headers
  plugin :typecast_params_sized_integers, sizes: [64], default_size: 64
  plugin :typecast_params do
    invalid_value_message(:pos_int64, "Value must be an integer greater than 0 for parameter")

    handle_type(:ubid_uuid, invalid_value_message: "Value provided not a valid id for parameter") do
      if it.is_a?(String) && it.bytesize == 26
        UBID.to_uuid(it)
      end
    end
  end

  plugin :symbol_matchers
  symbol_matcher(:ubid_uuid, /([a-tv-z0-9]{26})/) do |s|
    UBID.to_uuid(s)
  end

  # :nocov:
  if Config.test? && defined?(SimpleCov)
    plugin :render_coverage
  end
  # :nocov:

  plugin :host_routing, scope_predicates: true do |hosts|
    hosts.register :api, :web, :runtime
    hosts.default :web do |host|
      if host.start_with?("api.")
        :api
      elsif request.path_info.start_with?("/runtime")
        :runtime
      end
    end
  end

  plugin :conditional_sessions,
    key: "_Clover.session",
    cookie_options: {secure: !(Config.development? || Config.test?)},
    secret: Config.clover_session_secret do
      scope.web?
    end

  plugin :custom_block_results
  handle_block_result Integer do |status_code|
    response.status = status_code
    nil
  end

  plugin :route_csrf do |token|
    response.status = 400
    @page_title = "Invalid Security Token"
    view(content: "An invalid security token was submitted, please click back, refresh, and try again.")
  end

  plugin :content_security_policy do |csp|
    csp.default_src :none
    csp.style_src :self, "https://cdn.jsdelivr.net/npm/flatpickr@4.6.13/dist/flatpickr.min.css"
    csp.img_src :self, "data: image/svg+xml", "https://github.com", "https://avatars.githubusercontent.com"
    csp.form_action :self, "https://checkout.stripe.com", "https://github.com/login/oauth/authorize", "https://accounts.google.com/o/oauth2/auth"
    csp.script_src :self, "https://cdn.jsdelivr.net/npm/jquery@3.7.0/dist/jquery.min.js", "https://cdn.jsdelivr.net/npm/dompurify@3.0.5/dist/purify.min.js", "https://cdn.jsdelivr.net/npm/flatpickr@4.6.13/dist/flatpickr.min.js", "https://challenges.cloudflare.com/turnstile/v0/api.js", "https://cdn.jsdelivr.net/npm/marked@15.0.5/marked.min.js", "https://cdn.jsdelivr.net/npm/echarts@5.6.0/dist/echarts.min.js"
    csp.frame_src :self, "https://challenges.cloudflare.com"
    csp.connect_src :self, "https://*.ubicloud.com"
    csp.base_uri :none
    csp.frame_ancestors :none
  end

  logger = if ENV["RACK_ENV"] == "test"
    Class.new {
      def write(_)
      end
    }.new
  else
    # :nocov:
    $stderr
    # :nocov:
  end
  plugin :common_logger, logger

  plugin :not_found do
    next if runtime?

    @error = {
      code: 404,
      type: "ResourceNotFound",
      message: "Sorry, we couldn’t find the resource you’re looking for."
    }

    if api? || request.headers["accept"] == "application/json"
      {error: @error}.to_json
    else
      view "/error"
    end
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
    if Config.test? && ENV["SHOW_ERRORS"]
      raise e
    end

    case e
    when Sequel::ValidationFailed, Roda::RodaPlugins::InvalidRequestBody::Error, Roda::RodaPlugins::TypecastParams::Error
      code = 400
      type = "InvalidRequest"
      message = e.to_s
    when CloverError
      code = e.code
      type = e.type
      message = e.message
      details = e.details
    when Committee::BadRequest, Committee::InvalidRequest
      code = 400
      type = "BadRequest"
      message = e.message

      case e.original_error
      when JSON::ParserError
        message = "Validation failed for following fields: body"
        details = {"body" => "Request body isn't a valid JSON object."}
      when OpenAPIParser::InvalidPattern
        pattern = e.original_error.instance_variable_get(:@pattern)
        value = e.original_error.instance_variable_get(:@value)
        message = "Parameter #{value.inspect} does not match pattern #{pattern}"
      when OpenAPIParser::NotExistPropertyDefinition
        keys = e.original_error.instance_variable_get(:@keys)
        message = "Validation failed for following fields: body"
        details = {"body" => "Request body contains unrecognized parameters: #{keys.join(", ")}"}
      when OpenAPIParser::NotExistRequiredKey
        keys = e.original_error.instance_variable_get(:@keys)
        message = "Validation failed for following fields: body"
        details = {"body" => "Request body must include required parameters: #{keys.join(", ")}"}
      end
    when Sequel::SerializationFailure
      code = 500
      type = "InternalServerError"
      message = "There was a temporary error attempting to make this change, please try again."
      Clog.emit("route exception") { Util.exception_to_hash(e) }
    else
      raise e if Config.test? && e.message != "test error"
      Clog.emit("route exception") { Util.exception_to_hash(e) }

      code = 500
      type = "UnexceptedError"
      message = "Sorry, we couldn’t process your request because of an unexpected error."
    end

    raise e if Config.test? && e.is_a?(Committee::Error)

    response.status = code
    next if code == 204

    error = {code:, type:, message:, details:}

    if runtime?
      error
    elsif api? || request.headers["accept"] == "application/json"
      {error:}
    else
      @error = error

      if e.is_a?(Sequel::ValidationFailed) || e.is_a?(DependencyError) || e.is_a?(Roda::RodaPlugins::TypecastParams::Error)
        flash["error"] = message
        redirect_back_with_inputs
      elsif e.is_a?(Sequel::SerializationFailure)
        flash["error"] = "There was a temporary error attempting to make this change, please try again."
        redirect_back_with_inputs
      elsif e.is_a?(CloverError) && !e.is_a?(Authorization::Unauthorized)
        flash["error"] = message
        flash["errors"] = (flash["errors"] || {}).merge(details || {}).transform_keys(&:to_s)

        if request.patch?
          response["location"] = env["HTTP_REFERER"]
          response.status = 200
          request.halt
        else
          redirect_back_with_inputs
        end
      end

      # :nocov:
      next exception_page(e, assets: true) if Config.development? && code == 500
      # :nocov:

      view "/error"
    end
  end

  require_relative "rodauth/features/personal_access_token"

  plugin :rodauth, name: :api do
    enable :json, :personal_access_token

    only_json? true

    invalid_auth_error_body = {
      "error" => {
        "code" => 401,
        "type" => "InvalidCredentials",
        "message" => "invalid personal access token provided in Authorization header"
      }
    }.to_json.freeze

    # The only response body that can be generated with this Rodauth configuration
    # is when the provided personal access token is invalid.  Generate the JSON
    # error body up front and serve it, so it doesn't need to be generated per-request.
    json_response_body do |_|
      invalid_auth_error_body
    end

    require_bcrypt? false
  end

  plugin :rodauth do
    enable :argon2, :change_login, :change_password, :close_account, :create_account,
      :lockout, :login, :logout, :remember, :reset_password,
      :disallow_password_reuse, :password_grace_period, :active_sessions,
      :verify_login_change, :change_password_notify, :confirm_password,
      :otp, :webauthn, :recovery_codes, :omniauth, :otp_unlock, :otp_lockout_email

    title_instance_variable :@page_title
    check_csrf? false

    # :nocov:
    unless Config.development?
      enable :disallow_common_passwords, :verify_account

      email_from Config.mail_from

      before_verify_account do
        if locked_domain_for(account[:email])
          transaction do
            DB[:account_verification_keys].where(id: account[:id]).delete
            before_close_account
            close_account
            after_close_account
            delete_account
          end
          check_locked_domain(account[:email], "Verifying accounts")
        end
      end
      verify_account_view { view "auth/verify_account", "Verify Account" }
      resend_verify_account_view { view "auth/verify_account_resend", "Resend Verification" }
      verify_account_email_sent_redirect { login_route }
      verify_account_email_recently_sent_redirect { login_route }
      verify_account_set_password? false
      verify_account_resend_explanatory_text "You need to wait at least 5 minutes before sending another verification email. If you did not receive the email, please check your spam folder."

      send_verify_account_email do
        Util.send_email(email_to, "Welcome to Ubicloud: Please Verify Your Account",
          greeting: "Welcome to Ubicloud,",
          body: ["To complete your registration and activate your account, click the button below.",
            "If you did not initiate this registration process, you may disregard this message.",
            "We're excited to serve you. Should you require any assistance, our customer support team stands ready to help at support@ubicloud.com."],
          button_title: "Verify Account",
          button_link: verify_account_email_link)
      end

      # Password Requirements
      password_minimum_length 8
      password_maximum_bytes 72
      password_meets_requirements? do |password|
        password.match?(/[a-z]/) && password.match?(/[A-Z]/) && password.match?(/[0-9]/)
      end

      invalid_password_message = "Password must have 8 characters minimum and contain at least one lowercase letter, one uppercase letter, and one digit."
      password_does_not_meet_requirements_message invalid_password_message
      password_too_short_message invalid_password_message
    end
    # :nocov:

    hmac_secret Config.clover_session_secret

    login_view { view "auth/login", "Login" }
    login_redirect { "/after-login" }
    login_return_to_requested_location? true
    login_label "Email Address"
    two_factor_auth_return_to_requested_location? true
    already_logged_in { redirect login_redirect }

    before_login do
      email = account[:email]
      if (locked_domain = locked_domain_for(email))
        error = if !omniauth_provider
          "Login via username and password"
        elsif omniauth_provider.to_s != locked_domain.oidc_provider.ubid
          "Login via #{scope.omniauth_provider_name(omniauth_provider)}"
        end

        if error
          flash["error"] = "#{error} is not supported for the #{domain_for_email(email)} domain. You must authenticate using #{locked_domain.oidc_provider.display_name}."
          redirect "/login"
        end
      end
    end

    after_login do
      remember_login if scope.typecast_params.str("remember-me") == "on"
      if omniauth_identity && omniauth_params["redirect_url"]
        flash["notice"] = "You have successfully connected your account with #{scope.omniauth_provider_name(omniauth_provider)}."
        # Don't trust the omniauth params, always redirect to the login methods page,
        # as that is the only page that should be setting redirect_url
        redirect "/account/login-method"
      end
    end

    update_session do
      if Account[account_session_value].suspended_at
        flash["error"] = "Your account has been suspended. " \
          "If you believe there's a mistake, or if you need further assistance, " \
          "please reach out to our support team at support@ubicloud.com."
        forget_login
        redirect login_route
      end
      super()
    end

    create_account_view { view "auth/create_account", "Create Account" }
    create_account_redirect { login_route }
    create_account_set_password? true
    password_confirm_label "Password Confirmation"
    before_create_account do
      scope.handle_validation_failure("auth/create_account")
      check_locked_domain(account[:email], "Creating accounts with a password")

      cf_response = scope.typecast_params.str("cf-turnstile-response").to_s if Config.cloudflare_turnstile_site_key

      if cf_response&.empty?
        Clog.emit("cloudflare turnstile parameter not submitted") { {user_agent: scope.env["HTTP_USER_AGENT"]} }
        scope.flash["error"] = "Could not create account. Please ensure JavaScript is enabled and access to Cloudflare is not blocked, then try again."
        request.redirect("/create-account")
      end

      Validation.validate_cloudflare_turnstile(cf_response)
      scope.before_rodauth_create_account(account, param("name"))
    end
    after_create_account do
      scope.after_rodauth_create_account(account_id)
    end

    use_multi_phase_login? true
    need_password_notice_flash "Login recognized"
    multi_phase_login_view { login_view }

    # :nocov:
    if Config.omniauth_github_id
      require "omniauth-github"
      omniauth_provider :github, Config.omniauth_github_id, Config.omniauth_github_secret, scope: "user:email"
    end
    if Config.omniauth_google_id
      require "omniauth-google-oauth2"
      omniauth_provider :google_oauth2, Config.omniauth_google_id, Config.omniauth_google_secret, name: :google
    end
    # :nocov:

    auth_class_eval do
      def check_locked_domain(email, error_prefix, redirect: nil)
        if (locked_domain = locked_domain_for(email))
          flash["error"] = "#{error_prefix} is not supported for the #{domain_for_email(email)} domain.#{" You must authenticate using #{locked_domain.oidc_provider.display_name}." unless redirect}"
          redirect(redirect || "/auth/#{locked_domain.oidc_provider.ubid}")
        end
      end

      # If the route isn't already handled and matches a known provider,
      # get the app specific to that provider, and then run it.
      def route_omniauth!
        super
        if (match = %r{\A/auth/(0p[a-tv-z0-9]{24})(?:/callback)?\z}.match(request.path_info)) &&
            (provider = OidcProvider[match[1]])
          omniauth_run omniauth_app_for_provider(provider)

          # :nocov:
          # Not reached in testing due to omniauth_setup throw above.
          handle_omniauth_callback
          # :nocov:
        end
        nil
      end

      def domain_for_email(email)
        email.split("@", 2)[1]
      end

      def locked_domain_for(email)
        LockedDomain.with_pk(domain_for_email(email))
      end

      omniauth_apps = {}
      omniauth_app_mutex = Mutex.new
      builder_app = ->(env) { [404, {}, []] }

      # Return OIDC-provider specific omniauth app.  If there isn't an existing
      # app for the provider in this process, build one.
      define_method(:omniauth_app_for_provider) do |provider|
        name = provider.ubid
        if (app = omniauth_app_mutex.synchronize { omniauth_apps[name] })
          return app
        end

        # Delay loading of omniauth_oidc until it is needed. Generally, this type of
        # runtime require doesn't work with a frozen environment, but it does in this
        # as the file does not modify any frozen constants. This is helpful so that
        # users do not have to pay the cost of loading the file if they do not have
        # any OidcProviders.
        require_relative "vendor/omniauth_oidc"

        # This part is copied from rodauth-omniauth's omniauth_app method in order
        # to integrate with rodauth-omniauth.
        builder = OmniAuth::Builder.new
        builder.options(
          path_prefix: omniauth_prefix,
          setup: ->(env) { env["rodauth.omniauth.instance"].send(:omniauth_setup) }
        )
        builder.configure do |config|
          [:request_validation_phase, :before_request_phase, :before_callback_phase, :on_failure].each do |hook|
            config.send(:"#{hook}=", ->(env) { env["rodauth.omniauth.instance"].send(:"omniauth_#{hook}") })
          end
        end

        # Only use the provider passed to the method. rodauth-omniauth uses all
        # statically configured providers in omniauth_app
        uri = URI(provider.url)
        builder.provider :oidc,
          name: name.to_sym,
          issuer: provider.url,
          client_options: {
            port: uri.port,
            scheme: uri.scheme,
            host: uri.host,
            identifier: provider.client_id,
            secret: provider.client_secret,
            redirect_uri: provider.callback_url,
            authorization_endpoint: provider.authorization_endpoint,
            token_endpoint: provider.token_endpoint,
            userinfo_endpoint: provider.userinfo_endpoint
          }

        builder.run builder_app
        app = builder.to_app
        omniauth_app_mutex.synchronize { omniauth_apps[name] ||= app }
      end
    end

    before_omniauth_create_account do
      unless (email = account[:email])
        flash["error"] = "Social login is only allowed if social login provider provides email"
        redirect "/login"
      end

      if (locked_domain = locked_domain_for(email)) && omniauth_provider.to_s != locked_domain.oidc_provider.ubid
        flash["error"] = "Creating an account via authentication through #{scope.omniauth_provider_name(omniauth_provider)} is not supported for the #{domain_for_email(email)} domain. You must authenticate using #{locked_domain.oidc_provider.display_name}."
        redirect "/login"
      end

      scope.before_rodauth_create_account(account, omniauth_name || account[:email].split("@", 2)[0].gsub(/[^A-Za-z]+/, " ").capitalize)
    end

    after_omniauth_create_account do
      scope.after_rodauth_create_account(account_id)
    end

    omniauth_on_failure do
      Clog.emit("omniauth failure") { {omniauth_error:, omniauth_error_type:, omniauth_error_strategy:, backtrace: omniauth_error.backtrace} }
      super()
    end

    before_omniauth_callback_route do
      account = Account[account_from_omniauth&.[](:id)]
      if authenticated?
        unless account && account.id == scope.current_account.id
          flash["error"] = "Your account's email address is different from the email address associated with the #{scope.omniauth_provider_name(omniauth_provider)} account."
          redirect "/account/login-method"
        end
      elsif account && account.identities_dataset.where(provider: omniauth_provider.to_s).empty?
        provider_name = scope.omniauth_provider_name(omniauth_provider)
        flash["error"] = "There is already an account with this email address, and it has not been linked to the #{provider_name} account.
        Please login to the existing account normally, and then link it to the #{provider_name} account from your account settings.
        Then you can login using the #{provider_name} account."
        redirect "/login"
      end
    end

    omniauth_create_account? { !authenticated? }

    before_unlock_account { check_locked_domain(account[:email], "Unlocking accounts") }
    before_unlock_account_request { check_locked_domain(account[:email], "Unlocking accounts") }

    before_reset_password { check_locked_domain(account[:email], "Resetting passwords") }
    reset_password_view { view "auth/reset_password", "Request Password" }
    reset_password_request_view { view "auth/reset_password_request", "Request Password Reset" }
    reset_password_redirect { login_route }
    reset_password_email_sent_redirect { login_route }
    reset_password_email_recently_sent_redirect { reset_password_request_route }

    send_reset_password_email do
      user = Account[account_id]
      Util.send_email(user.email, "Reset Ubicloud Account Password",
        greeting: "Hello #{user.name},",
        body: ["We received a request to reset your account password. To reset your password, click the button below.",
          "If you did not initiate this request, no action is needed. Your account remains secure.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."],
        button_title: "Reset Password",
        button_link: reset_password_email_link)
    end

    before_reset_password_request do
      check_locked_domain(account[:email], "Resetting passwords")
      unless has_password?
        flash["error"] = "Login with password is not enabled for this account. Please use other login methods. For any questions or assistance, reach out to our team at support@ubicloud.com"
        redirect login_route
      end
    end
    reset_password_explanatory_text "If you have forgotten your password, you can request a password reset:"

    after_reset_password do
      remove_all_active_sessions_except_current
    end

    before_change_password { check_locked_domain(account[:email], "Changing passwords", redirect: "/") }
    change_password_redirect "/account/change-password"
    change_password_route "account/change-password"
    change_password_view { view "account/change_password", "My Account" }
    after_change_password do
      remove_all_active_sessions_except_current
    end

    send_password_changed_email do
      user = Account[account_id]
      Util.send_email(email_to, "Ubicloud Account Password Changed",
        greeting: "Hello #{user.name},",
        body: ["Someone has changed the password for the account associated to this email address.",
          "If you did not initiate this request or for any questions, reach out to our team at support@ubicloud.com."])
    end

    before_change_login do
      check_locked_domain(account[:email], "Changing email addresses", redirect: "/")
      check_locked_domain(param("login"), "Changing email addresses", redirect: "/")
    end
    change_login_redirect "/account/change-login"
    change_login_route "account/change-login"
    change_login_view { view "account/change_login", "My Account" }

    before_verify_login_change do
      check_locked_domain(account[:email], "Changing email addresses", redirect: "/")
      check_locked_domain(verify_login_change_new_login, "Changing email addresses", redirect: "/")
    end
    verify_login_change_view { view "auth/verify_login_change", "Verify Email Change" }
    send_verify_login_change_email do |new_login|
      user = Account[account_id]
      Util.send_email(email_to, "Please Verify New Email Address for Ubicloud",
        greeting: "Hello #{user.name},",
        body: ["We received a request to change your account email to '#{new_login}'. To verify new email, click the button below.",
          "If you did not initiate this request, no action is needed. Current email address can be used to login your account.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."],
        button_title: "Verify Email",
        button_link: verify_login_change_email_link)
    end
    after_verify_login_change do
      remove_all_active_sessions_except_current
    end

    close_account_redirect "/login"
    close_account_route "account/close-account"
    close_account_view { view "account/close_account", "My Account" }

    before_close_account do
      scope.handle_validation_failure(true) do
        request.on do
          close_account_view
        end
      end
      account = Account[account_id]
      # Do not allow to close account if the project has resources and
      # the account is the only user
      projects_dataset = Project
        .where(id: DB[:access_tag]
          .select_group(:project_id)
          .where(project_id: account.projects_dataset.select(Sequel[:project][:id]))
          .having(Sequel.function(:count).* => 1))

      if (project = projects_dataset.first_project_with_resources)
        fail DependencyError.new("'#{project.name}' project has some resources. Delete all related resources first.")
      end
    end

    delete_account_on_close? true
    delete_account do
      Account[account_id].destroy
    end

    argon2_secret { Config.clover_session_secret }
    require_bcrypt? false

    # Multifactor Manage
    two_factor_manage_route "account/multifactor-manage"
    two_factor_manage_view { view "account/two_factor_manage", "My Account" }

    # Multifactor Auth
    two_factor_auth_view { view "auth/two_factor_auth", "Two-factor Authentication" }
    two_factor_auth_notice_flash { login_notice_flash }
    # don't show error message when redirected after login
    # :nocov:
    two_factor_need_authentication_error_flash { (flash["notice"] == login_notice_flash) ? nil : super() }
    # :nocov:

    # If the single multifactor auth method is setup, redirect to it
    before_two_factor_auth_route do
      redirect otp_auth_path if otp_exists? && !webauthn_setup?
      redirect webauthn_auth_path if webauthn_setup? && !otp_exists?
    end

    # OTP Setup
    otp_setup_route "account/multifactor/otp-setup"
    otp_setup_view { view "account/multifactor/otp_setup", "My Account" }
    otp_setup_link_text "Enable"
    otp_setup_button "Enable One-Time Password Authentication"
    otp_setup_notice_flash "One-time password authentication is now setup, please make note of your recovery codes"
    otp_setup_error_flash "Error setting up one-time password authentication"

    # :nocov:
    after_otp_setup do
      flash["notice"] = otp_setup_notice_flash
      redirect "/" + recovery_codes_route
    end
    # :nocov:

    # OTP Disable
    otp_disable_route "account/multifactor/otp-disable"
    otp_disable_view { view "account/multifactor/otp_disable", "My Account" }
    otp_disable_link_text "Disable"
    otp_disable_button "Disable One-Time Password Authentication"
    otp_disable_notice_flash "One-time password authentication has been disabled"
    otp_disable_error_flash "Error disabling one-time password authentication"
    otp_disable_redirect { "/" + two_factor_manage_route }

    # OTP Auth
    otp_auth_view { view "auth/otp_auth", "One-Time" }
    otp_auth_button "Authenticate Using One-Time Password"
    otp_auth_link_text "One-Time Password Generator"

    # OTP Unlock
    otp_unlock_view { view "auth/otp_unlock", "One-Time Password Unlock" }
    otp_unlock_not_available_view { view "auth/otp_unlock_not_available", "One-Time Password Unlock Not Available" }
    otp_unlock_button "Authenticate Using One-Time Password to Unlock"
    otp_unlocked_redirect "/otp-auth"
    otp_unlocked_notice_flash "One-Time Password authentication unlocked"
    otp_unlock_auth_success_notice_flash "One-Time Password successful authentication, more successful authentication needed to unlock"
    otp_unlock_not_locked_out_error_flash "One-Time Password authentication is not currently locked out"
    otp_unlock_auth_failure_error_flash "One-Time Password invalid authentication"
    otp_unlock_auth_deadline_passed_error_flash "Deadline past for unlocking One-Time Password authentication"
    otp_unlock_auth_not_yet_available_error_flash "One-Time Password unlock attempt not yet available"

    # OTP Unlock Email
    send_otp_locked_out_email do
      user = Account[account_id]
      Util.send_email(user.email, "Ubicloud Account One-Time Password Authentication Locked Out",
        greeting: "Hello #{user.name},",
        body: ["Due to repeated authentication failures, for the safety of your Ubicloud account, One-Time Password Authentication has been locked out. You can unlock it with three successful consecutive One-Time Password Authentications.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."])
    end
    send_otp_unlocked_email do
      user = Account[account_id]
      Util.send_email(user.email, "Ubicloud Account One-Time Password Authentication Unlocked",
        greeting: "Hello #{user.name},",
        body: ["Since your Ubicloud account had three successful consecutive One-Time Password Authentications,  One-Time Password Authentication is now unlocked for your account.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."])
    end

    # Webauthn Setup
    webauthn_setup_route "account/multifactor/webauthn-setup"
    webauthn_setup_view { view "account/multifactor/webauthn_setup", "My Account" }
    webauthn_setup_link_text "Add"
    webauthn_setup_button "Setup Security Key"
    webauthn_setup_notice_flash "Security key is now setup, please make note of your recovery codes"
    webauthn_setup_error_flash "Error setting up security key"
    webauthn_key_insert_hash { |credential| super(credential).merge(name: scope.typecast_params.nonempty_str!("name")) }

    # :nocov:
    after_webauthn_setup do
      flash["notice"] = webauthn_setup_notice_flash
      redirect "/" + recovery_codes_route
    end
    # :nocov:

    # Webauthn Remove
    webauthn_remove_route "account/multifactor/webauthn-remove"
    webauthn_remove_view { view "account/multifactor/webauthn_remove", "My Account" }
    webauthn_remove_link_text "Remove"
    webauthn_remove_button "Remove Security Key"
    webauthn_remove_notice_flash "Security key has been removed"
    webauthn_remove_error_flash "Error removing security key"
    webauthn_invalid_remove_param_message "Invalid security key to remove"
    webauthn_remove_redirect { "/" + two_factor_manage_route }

    # Webauthn Auth
    webauthn_auth_view { view "auth/webauthn_auth", "Security Keys" }
    webauthn_auth_button "Authenticate Using Security Keys"
    webauthn_auth_link_text "Security Keys"

    # Recovery Codes
    recovery_codes_route "account/multifactor/recovery-codes"
    recovery_codes_view { view "account/multifactor/recovery_codes", "My Account" }
    recovery_codes_link_text "View"
    add_recovery_codes_view { view "account/multifactor/recovery_codes", "My Account" }
    auto_add_recovery_codes? true
    auto_remove_recovery_codes? true
    add_recovery_codes_heading "Add Additional Recovery Codes"
    recovery_auth_view { view "auth/recovery_auth", "Recovery Codes" }
  end

  hash_branch("after-login") do |r|
    r.get web? do
      no_authorization_needed
      redirect_default_project_dashboard
    end
  end

  # :nocov:
  if Config.test?
    # :nocov:
    hash_branch(:webhook_prefix, "test-error") do |r|
      raise(typecast_params.str("message") || "test error")
    end

    hash_branch(:webhook_prefix, "test-typecast-error-during-validation-failure") do |r|
      r.POST["a"] = {}
      handle_validation_failure(inline: "<%= typecast_body_params.str('a') %>")
      typecast_body_params.str("a")
    end

    hash_branch(:webhook_prefix, "test-no-audit-logging") do |r|
      r.post "test" do
        @still_need_audit_logging = true
        ""
      end

      r.post "bad" do
        audit_log(@project, "bad_action")
      end
    end

    hash_branch("test-no-authorization-needed") do |r|
      r.get "never" do
        ""
      end

      r.get "once" do
        no_authorization_needed
        ""
      end

      r.get "twice" do
        2.times { no_authorization_needed }
      end

      r.get "after-authorization" do
        @project = current_account.projects.first
        dataset_authorize(current_account.projects_dataset, "Project:edit")
        no_authorization_needed
      end

      r.get "authorization-error" do
        raise Authorization::Unauthorized
      end

      r.get "runtime-error" do
        raise "foo"
      end
    end

    hash_branch("clear-last-password-entry") do |r|
      no_authorization_needed
      session.delete("last_password_entry")
      ""
    end
  end

  if Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
    Unreloader.require("routes")
  # :nocov:
  else
    plugin :autoload_hash_branches
    Dir["routes/**/*.rb"].each do |full_path|
      parts = full_path.delete_prefix("routes/").split("/")
      namespaces = parts[0...-1]
      filename = parts.last
      segment = File.basename(filename, ".rb").tr("_", "-")
      namespace = if namespaces.empty?
        ""
      else
        :"#{namespaces.join("_")}_prefix"
      end
      autoload_hash_branch(namespace, segment, full_path)
    end
    Unreloader.autoload("routes", delete_hook: proc { |f| hash_branch(File.basename(f, ".rb").tr("_", "-")) }) {}
  end
  # :nocov:

  route do |r|
    if api?
      unless /\ABearer:?\s+pat-/i.match?(env["HTTP_AUTHORIZATION"].to_s)
        if r.path_info == "/cli"
          response["content-type"] = "text/plain"
          response.status = 400
          next "! Invalid request: No valid personal access token provided\n"
        else
          response.json = true
          fail CloverError.new(401, "MissingCredentials", "must include personal access token in Authorization header")
        end
      end
      response.json = true
      response.skip_content_security_policy!
    else
      r.on "runtime" do
        response.json = true
        response.skip_content_security_policy!

        unless (jwt_payload = get_runtime_jwt_payload) && (@vm = Vm[id: UBID.to_uuid(jwt_payload["sub"])])
          fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization header")
        end

        before_main_hash_branches
        r.hash_branches(:runtime_prefix)
      end

      r.public
      r.assets

      r.on "webhook" do
        before_main_hash_branches
        r.hash_branches(:webhook_prefix)
      end

      r.get "auth", :ubid_uuid do |id|
        next unless (@oidc_provider = OidcProvider[id])

        r.get do
          uri = URI(@oidc_provider.url)
          uri.path = ""
          content_security_policy.add_form_action(uri.to_s)
          view "auth/oidc_login"
        end
      end

      check_csrf!
      rodauth.load_memory
      rodauth.check_active_session

      r.root do
        if current_account
          redirect_default_project_dashboard
        else
          r.redirect rodauth.login_route
        end
      end
    end

    r.rodauth
    rodauth.require_authentication

    if api? && r.path_info != "/cli"
      # Validate request against OpenAPI schema, after authenticating
      # (which is thought to be cheaper)
      begin
        @schema_validator = SCHEMA_ROUTER.build_schema_validator(r)
        @schema_validator.request_validate(r)

        next unless @schema_validator.link_exist?
      rescue JSON::ParserError => e
        raise Committee::InvalidRequest.new("Request body wasn't valid JSON.", original_error: e)
      end
    end

    before_authenticated_hash_branches
    r.hash_branches("")
  end

  # Validate response against OpenAPI schema
  after do |res|
    status, headers, body = res
    next unless api? && status && headers && body
    @schema_validator ||= SCHEMA_ROUTER.build_schema_validator(request)
    @schema_validator.response_validate(status, headers, body, true) if @schema_validator.link_exist?
  rescue JSON::ParserError => e
    raise Committee::InvalidResponse.new("Response body wasn't valid JSON.", original_error: e)
  end

  # :nocov:
  if Config.test? && ENV["CLOVER_FREEZE"] != "1"
    # :nocov:

    # This section is included when running non-frozen specs, and ensures that all routes
    # either call an authorization method, or explicitly indicate that no additional authorization
    # is needed by calling no_authorization_needed

    after do |res|
      if @still_need_authorization
        if res
          case res[0]
          when 404, 501
            next
          end
        else
          case $!
          when Authorization::Unauthorized
            next
          end

          # Allow easier debugging of issues, by not raising a RuntimeError if there is a separate
          # error being raised and you are explicitly requesting showing it.
          next if ENV["SHOW_ERRORS"]
        end

        raise "no authorization check for #{request.request_method} #{request.path_info}"
      end

      if !request.get? && @still_need_audit_logging && res && res[0] < 400 && res[0] != 204 && (api? || !flash.next["error"])
        raise "no audit logging for #{request.request_method} #{request.path_info}"
      end
    end

    prepend(Module.new do
      def before_authenticated_hash_branches
        # Set the audit logging and authorization flags, which will be unset by
        # the related methods, to ensure that all routes have some form of authorization,
        # all add non-GET routes have some form of audit logging.
        @still_need_audit_logging = true
        @still_need_authorization = true
        before_main_hash_branches
      end

      def before_main_hash_branches
        # Disallow direct access of request.params in routes, only allow access
        # through typecast_params
        typecast_params
        request.singleton_class.send(:undef_method, :params)

        # Need to rewind body so webhook github requests work
        request.body.rewind unless request.get?
      end

      def audit_log(...)
        @still_need_audit_logging = false
        super
      end

      def no_audit_log
        @still_need_audit_logging = false
        super
      end

      def authorize(actions, object_id)
        @still_need_authorization = false
        super
      end

      def has_permission?(actions, object_id)
        @still_need_authorization = false
        super
      end

      def dataset_authorize(ds, actions)
        @still_need_authorization = false
        super
      end

      def no_authorization_needed
        raise "called no_authorization_needed when authorization already not needed: #{request.inspect}" unless @still_need_authorization
        @still_need_authorization = false
        super
      end
    end)
  end
end
