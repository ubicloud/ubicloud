# frozen_string_literal: true

require_relative "model"

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
    csp.style_src :self, "https://maxcdn.bootstrapcdn.com"
    csp.form_action :self
    csp.script_src :self
    csp.connect_src :self
    csp.base_uri :none
    csp.frame_ancestors :none
  end

  plugin :route_csrf
  plugin :flash
  plugin :assets, css: "app.scss", css_opts: {style: :compressed, cache: false}, timestamp_paths: true
  plugin :render, escape: true, layout: "./layout"
  plugin :public
  plugin :Integer_matcher_max
  plugin :typecast_params_sized_integers, sizes: [64], default_size: 64
  plugin :hash_branch_view_subdir

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
    @page_title = "File Not Found"
    view(content: "")
  end

  if ENV["RACK_ENV"] == "development"
    plugin :exception_page
    class RodaRequest
      def assets
        exception_page_assets
        super
      end
    end
  else
    def self.freeze
      Sequel::Model.freeze_descendents
      DB.freeze
      super
    end
  end

  plugin :error_handler do |e|
    case e
    when Roda::RodaPlugins::RouteCsrf::InvalidToken
      @page_title = "Invalid Security Token"
      response.status = 400
      view(content: "<p>An invalid security token was submitted with this request, and this request could not be processed.</p>")
    else
      $stderr.print "#{e.class}: #{e.message}\n"
      warn e.backtrace
      next exception_page(e, assets: true) if ENV["RACK_ENV"] == "development"
      @page_title = "Internal Server Error"
      view(content: "")
    end
  end

  secret = Base64.decode64(Config.clover_session_secret)
  plugin :sessions,
    key: "_Clover.session",
    # cookie_options: {secure: ENV['RACK_ENV'] != 'test'}, # Uncomment if only allowing https:// access
    secret: secret

  if Config.development?
    Unreloader.require("routes", delete_hook: proc { |f| hash_branch(File.basename(f).delete_suffix(".rb")) }) {}
  end

  plugin :rodauth do
    enable :login, :logout, :verify_account
    enable :otp, :recovery_codes
    hmac_secret secret
    require_bcrypt? false
  end

  route do |r|
    r.rodauth
    rodauth.require_authentication
    r.public
    r.assets
    check_csrf!

    r.hash_branches("")

    r.root do
      view "index"
    end
  end
end
