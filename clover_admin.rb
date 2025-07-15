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

  route do |r|
    r.public

    # :nocov:
    r.exception_page_assets if Config.development?
    # :nocov:

    view(content: r.env["HTTP_HOST"])
  end
end
