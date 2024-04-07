# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Invoice do
  subject(:invoice) { described_class.new(id: "50d5aae4-311c-843b-b500-77fbc7778050", content: {"cost" => 10}, status: "unpaid") }

  let(:billing_info) { BillingInfo.create_with_id(stripe_id: "cs_1234567890") }
  let(:payment_method) { PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_1234567890") }

  describe ".charge" do
    it "not charge if Stripe not enabled" do
      allow(Config).to receive(:stripe_secret_key).and_return(nil)
      expect do
        expect(invoice.charge).to be_nil
      end.to output("Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing.\n").to_stdout
    end

    it "not charge if already charged" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      invoice.status = "paid"
      expect do
        expect(invoice.charge).to be_nil
      end.to output("Invoice[1va3atns1h3j3pm07fyy7ey050] already charged: paid\n").to_stdout
    end

    it "not charge if less than minimum charge threshold" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      invoice.content["cost"] = 0.4
      expect(invoice).to receive(:update).with(status: "below_minimum_threshold")
      expect do
        expect(invoice.charge).to be_nil
      end.to output("Invoice[1va3atns1h3j3pm07fyy7ey050] cost is less than minimum charge cost: $0.4\n").to_stdout
    end

    it "not charge if doesn't have billing info" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      expect do
        expect(invoice.charge).to be_nil
      end.to output("Invoice[1va3atns1h3j3pm07fyy7ey050] doesn't have billing info\n").to_stdout
    end

    it "not charge if no payment methods" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      invoice.content["billing_info"] = {"id" => billing_info.id}
      expect do
        expect(invoice.charge).to be_nil
      end.to output("Invoice[1va3atns1h3j3pm07fyy7ey050] couldn't charge with any payment method\n").to_stdout
    end

    it "not charge if payment method fails" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      invoice.content["billing_info"] = {"id" => billing_info.id}
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::PaymentIntent).to receive(:create).and_return(double(Stripe::PaymentIntent, status: "failed")).at_least(:once)
      # rubocop:enable RSpec/VerifiedDoubles
      expect do
        expect(invoice.charge).to be_nil
      end.to output("Invoice[1va3atns1h3j3pm07fyy7ey050] couldn't charge with PaymentMethod[#{payment_method.ubid}]: failed
Invoice[1va3atns1h3j3pm07fyy7ey050] couldn't charge with any payment method\n").to_stdout
    end

    it "can charge" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      invoice.content["billing_info"] = {"id" => billing_info.id}

      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::PaymentIntent).to receive(:create).and_return(double(Stripe::PaymentIntent, status: "succeeded", id: "pi_1234567890")).with(hash_including(
        amount: 1000,
        customer: billing_info.stripe_id,
        payment_method: payment_method.stripe_id
      )).at_least(:once)
      # rubocop:enable RSpec/VerifiedDoubles
      expect(invoice).to receive(:save).with(columns: [:status, :content])
      expect do
        expect(invoice.charge).to eq("pi_1234567890")
      end.to output("Invoice[1va3atns1h3j3pm07fyy7ey050] charged with PaymentMethod[#{payment_method.ubid}] for $10.0\n").to_stdout
      expect(invoice.status).to eq("paid")
      expect(invoice.content["payment_method"]["id"]).to eq(payment_method.id)
      expect(invoice.content["payment_intent"]).to eq("pi_1234567890")
    end
  end
end
