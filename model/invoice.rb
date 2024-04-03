# frozen_string_literal: true

require_relative "../model"
require "stripe"

class Invoice < Sequel::Model
  include ResourceMethods

  def path
    "/invoice/#{id ? ubid : "current"}"
  end

  def name
    begin_time.strftime("%B %Y")
  end

  def charge
    reload # Reload to get the latest status to avoid double charging
    unless (Stripe.api_key = Config.stripe_secret_key)
      Clog.emit("Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing.")
      return true
    end

    if status != "unpaid"
      Clog.emit("Invoice already charged.") { {invoice_already_charged: {ubid: ubid, status: status}} }
      return true
    end

    amount = content["cost"].to_f.round(2)
    if amount < Config.minimum_invoice_charge_threshold
      update(status: "below_minimum_threshold")
      Clog.emit("Invoice cost is less than minimum charge cost.") { {invoice_below_threshold: {ubid: ubid, cost: amount}} }
      return true
    end

    if (billing_info = BillingInfo[content.dig("billing_info", "id")]).nil? || billing_info.payment_methods.empty?
      Clog.emit("Invoice doesn't have billing info.") { {invoice_no_billing: {ubid: ubid}} }
      return false
    end

    errors = []
    billing_info.payment_methods_dataset.order(:order).each do |pm|
      begin
        payment_intent = Stripe::PaymentIntent.create({
          amount: (amount * 100).to_i, # 100 cents to charge $1.00
          currency: "usd",
          confirm: true,
          off_session: true,
          customer: billing_info.stripe_id,
          payment_method: pm.stripe_id
        })
      rescue Stripe::CardError => e
        Clog.emit("Invoice couldn't charged.") { {invoice_not_charged: {ubid: ubid, payment_method: pm.ubid, error: e.message}} }
        errors << e.message
        next
      end

      unless payment_intent.status == "succeeded"
        Clog.emit("BUG: payment intent should succeed here") { {invoice_not_charged: {ubid: ubid, payment_method: pm.ubid, intent_id: payment_intent.id, error: payment_intent.status}} }
        next
      end

      Clog.emit("Invoice charged.") { {invoice_charged: {ubid: ubid, payment_method: pm.ubid, cost: amount}} }
      self.status = "paid"
      content.merge!({
        "payment_method" => {
          "id" => pm.id,
          "stripe_id" => pm.stripe_id
        },
        "payment_intent" => payment_intent.id
      })
      save(columns: [:status, :content])
      return true
    end

    Clog.emit("Invoice couldn't charged with any payment method.") { {invoice_not_charged: {ubid: ubid}} }
    false
  end
end

Invoice.unrestrict_primary_key
