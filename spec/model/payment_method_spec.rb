# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PaymentMethod do
  subject(:payment_method) { described_class.create_with_id(stripe_id: "pm_1234567890") }

  it "return Stripe Data if Stripe enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_1234567890").and_return({"id" => "pm_1234567890"})
    expect(payment_method.stripe_data).to eq({"id" => "pm_1234567890"})
  end

  it "not return Stripe Data if Stripe not enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return(nil)
    expect(Stripe::PaymentMethod).not_to receive(:retrieve)
    expect(payment_method.stripe_data).to be_nil
  end

  it "delete Stripe payment method if Stripe enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    expect(Stripe::PaymentMethod).to receive(:detach).with("pm_1234567890")
    payment_method.destroy
  end

  it "not delete Stripe payment method if Stripe not enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return(nil)
    expect(Stripe::PaymentMethod).not_to receive(:detach)
    payment_method.destroy
  end
end
