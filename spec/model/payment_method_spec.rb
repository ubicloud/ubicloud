# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe PaymentMethod do
  subject(:payment_method) { described_class.create(stripe_id: "pm_1234567890") }

  let(:payment_methods_service) { instance_double(Stripe::PaymentMethodService) }

  before do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    allow(StripeClient).to receive(:payment_methods).and_return(payment_methods_service)
  end

  it "return Stripe Data if Stripe enabled" do
    response = Stripe::StripeObject.construct_from(id: "pm_1234567890", card: {brand: "Visa", last4: "1234", exp_month: 12, exp_year: 2023, country: "NL", funding: "debit", wallet: {type: "apple_pay"}, checks: {address_line1_check: "pass", cvc_check: "pass"}})
    expect(payment_methods_service).to receive(:retrieve).with("pm_1234567890").and_return(response)
    expect(payment_method.stripe_data["brand"]).to eq("Visa")
    expect(payment_method.stripe_data["funding"]).to eq("debit")
    expect(payment_method.stripe_data["wallet"]["type"]).to eq("apple_pay")
  end

  it "not return Stripe Data if Stripe not enabled" do
    expect(Config).to receive(:stripe_secret_key).and_return(nil)
    expect(payment_methods_service).not_to receive(:retrieve)
    expect(payment_method.stripe_data).to be_nil
  end

  it "delete Stripe payment method if Stripe enabled" do
    expect(payment_methods_service).to receive(:detach).with("pm_1234567890")
    payment_method.destroy
  end

  it "not delete Stripe payment method if Stripe not enabled" do
    expect(Config).to receive(:stripe_secret_key).and_return(nil)
    expect(payment_methods_service).not_to receive(:detach)
    payment_method.destroy
  end
end
