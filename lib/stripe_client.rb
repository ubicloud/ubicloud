# frozen_string_literal: true

# rubocop:disable Naming/ConstantName
StripeClient = if Config.test?
  # rubocop:enable Naming/ConstantName
  Struct.new(:checkout, :customers, :payment_intents, :payment_methods, :setup_intents).new
  #:nocov:
elsif Config.stripe_secret_key
  require "stripe"
  Stripe::StripeClient.new(Config.stripe_secret_key).v1
  #:nocov:
end
