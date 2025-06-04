# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PaymentMethod do
  subject(:payment_method) { described_class.create_with_id(stripe_id: "pm_1234567890") }

  it "return Stripe Data if Stripe enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    expect(Stripe::PaymentMethod).to receive(:retrieve).with("pm_1234567890").and_return(Stripe::StripeObject.construct_from("id" => "pm_1234567890", "card" => Stripe::StripeObject.construct_from("brand" => "Visa", "last4" => "1234", "exp_month" => 12, "exp_year" => 2023)))
    expect(payment_method.stripe_data).to eq({"brand" => "Visa", "last4" => "1234", "exp_month" => 12, "exp_year" => 2023})
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
