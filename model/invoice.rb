# frozen_string_literal: true

require_relative "../model"
require "stripe"

class Invoice < Sequel::Model
  many_to_one :project

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
      send_success_email(below_threshold: true)
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
      send_success_email
      return true
    end

    Clog.emit("Invoice couldn't charged with any payment method.") { {invoice_not_charged: {ubid: ubid}} }
    false
  end

  def send_success_email(below_threshold: false)
    ser = Serializers::Web::Invoice.new(:detailed).serialize(self)
    message = if below_threshold
      "Since the invoice total of #{ser[:total]} is below our minimum charge threshold, there will be no charges for this month."
    else
      "The invoice amount of #{ser[:total]} will be debited from your credit card on file."
    end
    Util.send_email(ser[:billing_email], "Ubicloud #{ser[:name]} Invoice ##{ser[:invoice_number]}",
      greeting: "Dear #{ser[:billing_name]},",
      body: ["Please find your current invoice ##{ser[:invoice_number]} at the link.",
        message,
        "If you have any questions, please send us a support request via support@ubicloud.com, and include your invoice number."],
      button_title: "View Invoice",
      button_link: "#{Config.base_url}#{project.path}/billing#{ser[:path]}")
  end
end

Invoice.unrestrict_primary_key
