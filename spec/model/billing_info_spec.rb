# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe BillingInfo do
  subject(:billing_info) { described_class.create_with_id(stripe_id: "cs_1234567890") }

  it "return Stripe Data if Stripe enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    expect(Stripe::Customer).to receive(:retrieve).with("cs_1234567890").and_return({"name" => "John Doe", "address" => {"line1" => "123 Main St"}, "metadata" => {}})
    expect(billing_info.stripe_data["name"]).to eq("John Doe")
    expect(billing_info.stripe_data["address"]).to eq("123 Main St")
  end

  it "not return Stripe Data if Stripe not enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return(nil)
    expect(Stripe::Customer).not_to receive(:retrieve)
    expect(billing_info.stripe_data).to be_nil
  end

  it "delete Stripe customer if Stripe enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
    expect(Stripe::Customer).to receive(:delete).with("cs_1234567890")

    billing_info.destroy
  end

  it "not delete Stripe customer if Stripe not enabled" do
    allow(Config).to receive(:stripe_secret_key).and_return(nil)
    expect(Stripe::Customer).not_to receive(:delete)

    billing_info.destroy
  end
end
