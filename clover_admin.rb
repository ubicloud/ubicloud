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
    # :nocov:
    # Cover after we have a form submitting a POST request
    flash.now["error"] = "An invalid security token submitted with this request, please try again"
    @page_title = "Invalid Security Token"
    view(content: "")
    # :nocov:
  end

  plugin :forme_route_csrf
  Forme.register_config(:clover_admin, base: :default, labeler: :explicit)
  Forme.default_config = :clover_admin

  route do |r|
    r.public

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
