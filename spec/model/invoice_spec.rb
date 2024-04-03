# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Invoice do
  subject(:invoice) { described_class.new(id: "50d5aae4-311c-843b-b500-77fbc7778050", content: {"cost" => 10}, status: "unpaid") }

  let(:billing_info) { BillingInfo.create_with_id(stripe_id: "cs_1234567890") }

  before do
    allow(invoice).to receive(:reload)
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
  end

  describe ".charge" do
    it "not charge if Stripe not enabled" do
      allow(Config).to receive(:stripe_secret_key).and_return(nil)
      expect(Clog).to receive(:emit).with("Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing.").and_call_original
      expect(invoice.charge).to be true
    end

    it "not charge if already charged" do
      expect(Clog).to receive(:emit).with("Invoice already charged.").and_call_original
      invoice.status = "paid"
      expect(invoice.charge).to be true
    end

    it "not charge if less than minimum charge threshold" do
      invoice.content["cost"] = 0.4
      expect(invoice).to receive(:update).with(status: "below_minimum_threshold")
      expect(Clog).to receive(:emit).with("Invoice cost is less than minimum charge cost.").and_call_original
      expect(invoice.charge).to be true
    end

    it "not charge if doesn't have billing info" do
      expect(Clog).to receive(:emit).with("Invoice doesn't have billing info.").and_call_original
      expect(invoice.charge).to be false
    end

    it "not charge if no payment methods" do
      invoice.content["billing_info"] = {"id" => billing_info.id}
      expect(Clog).to receive(:emit).with("Invoice doesn't have billing info.").and_call_original
      expect(invoice.charge).to be false
    end

    it "not charge if all payment methods fails" do
      invoice.content["billing_info"] = {"id" => billing_info.id}
      payment_method1 = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_1", order: 1)
      payment_method2 = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_2", order: 2)

      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(amount: 1000, customer: billing_info.stripe_id, payment_method: payment_method1.stripe_id))
        .and_raise(Stripe::CardError.new("Unsufficient funds", {}))
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(amount: 1000, customer: billing_info.stripe_id, payment_method: payment_method2.stripe_id))
        .and_raise(Stripe::CardError.new("Card declined", {}))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(Clog).to receive(:emit).with("Invoice couldn't charged.").and_call_original.twice
      expect(Clog).to receive(:emit).with("Invoice couldn't charged with any payment method.").and_call_original
      expect(invoice.charge).to be false
    end

    it "fails if PaymentIntent does not raise an exception in case of failure" do
      invoice.content["billing_info"] = {"id" => billing_info.id}
      payment_method = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_1", order: 1)

      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(amount: 1000, customer: billing_info.stripe_id, payment_method: payment_method.stripe_id))
        .and_return(double(Stripe::PaymentIntent, id: "payment-intent-id", status: "failed"))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(Clog).to receive(:emit).with("BUG: payment intent should succeed here").and_call_original
      expect(Clog).to receive(:emit).with("Invoice couldn't charged with any payment method.").and_call_original
      expect(invoice.charge).to be false
    end

    it "can charge from a correct payment method even some of them are not working" do
      invoice.content["billing_info"] = {"id" => billing_info.id}
      payment_method1 = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_1", order: 1)
      payment_method2 = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_2", order: 2)
      payment_method3 = PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_3", order: 3)
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(amount: 1000, customer: billing_info.stripe_id, payment_method: payment_method1.stripe_id))
        .and_raise(Stripe::CardError.new("Declined", {}))
      expect(Stripe::PaymentIntent).to receive(:create).with(hash_including(amount: 1000, customer: billing_info.stripe_id, payment_method: payment_method2.stripe_id))
        .and_return(double(Stripe::PaymentIntent, status: "succeeded", id: "pi_1234567890"))
      expect(Stripe::PaymentIntent).not_to receive(:create).with(hash_including(payment_method: payment_method3.stripe_id))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(invoice).to receive(:save).with(columns: [:status, :content])
      expect(Clog).to receive(:emit).with("Invoice couldn't charged.").and_call_original
      expect(Clog).to receive(:emit).with("Invoice charged.").and_call_original
      expect(invoice.charge).to be true
      expect(invoice.status).to eq("paid")
      expect(invoice.content["payment_method"]["id"]).to eq(payment_method2.id)
      expect(invoice.content["payment_intent"]).to eq("pi_1234567890")
    end
  end
end
