# frozen_string_literal: true

require_relative "../model"
require "stripe"

class Invoice < Sequel::Model
  include ResourceMethods

  def path
    "/invoice/#{ubid}"
  end

  def name
    begin_time.strftime("%B %Y")
  end

  def charge
    unless (Stripe.api_key = Config.stripe_secret_key)
      puts "Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing."
      return
    end

    if status != "unpaid"
      puts "Invoice[#{ubid}] already charged: #{status}"
      return
    end

    if content["cost"] < Config.minimum_invoice_charge_threshold
      update(status: "below_minimum_threshold")
      puts "Invoice[#{ubid}] cost is less than minimum charge cost: $#{content["cost"]}"
      return
    end

    unless (billing_info = BillingInfo[content.dig("billing_info", "id")])
      puts "Invoice[#{ubid}] doesn't have billing info"
      return
    end

    payment_methods = billing_info.payment_methods_dataset.order(:order).all

    payment_methods.each do |payment_method|
      amount = content["cost"].to_f.round(2)
      payment_intent = Stripe::PaymentIntent.create({
        amount: (amount * 100).to_i, # 100 cents to charge $1.00
        currency: "usd",
        confirm: true,
        off_session: true,
        customer: billing_info.stripe_id,
        payment_method: payment_method.stripe_id
      })

      if payment_intent.status == "succeeded"
        puts "Invoice[#{ubid}] charged with PaymentMethod[#{payment_method.ubid}] for $#{amount}"
        self.status = "paid"
        content.merge!({
          "payment_method" => {
            "id" => payment_method.id,
            "stripe_id" => payment_method.stripe_id
          },
          "payment_intent" => payment_intent.id
        })
        save(columns: [:status, :content])
        return payment_intent.id
      end

      puts "Invoice[#{ubid}] couldn't charge with PaymentMethod[#{payment_method.ubid}]: #{payment_intent.status}"
    end

    puts "Invoice[#{ubid}] couldn't charge with any payment method"
  end
end

Invoice.unrestrict_primary_key
