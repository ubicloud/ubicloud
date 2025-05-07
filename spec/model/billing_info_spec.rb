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

  describe ".has_address?" do
    it "returns true when Stripe customer has address" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      allow(Stripe::Customer).to receive(:retrieve).and_return({"address" => {"line1" => "Some Rd", "country" => "US"}, "metadata" => {}})
      expect(billing_info.has_address?).to be true
    end

    it "returns false when Stripe customer has no address" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      allow(Stripe::Customer).to receive(:retrieve).and_return({})
      expect(billing_info.has_address?).to be false
    end

    it "returns false when Stripe customer is nil" do
      allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
      allow(Stripe::Customer).to receive(:retrieve).and_return(nil)
      expect(billing_info.has_address?).to be false
    end
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

  describe ".validate_vat" do
    it "returns true if VAT number is valid" do
      stub_request(:get, "https://ec.europa.eu/taxation_customs/vies/rest-api/ms/NL/vat/123123").to_return(status: 200, body: {userError: "VALID"}.to_json)
      expect(billing_info).to receive(:stripe_data).and_return({"country" => "NL", "tax_id" => 123123}).at_least(:once)
      expect(billing_info.validate_vat).to be true
    end

    it "returns false if VAT number is invalid" do
      stub_request(:get, "https://ec.europa.eu/taxation_customs/vies/rest-api/ms/NL/vat/123123").to_return(status: 200, body: {userError: "INVALID"}.to_json)
      expect(billing_info).to receive(:stripe_data).and_return({"country" => "NL", "tax_id" => 123123}).at_least(:once)
      expect(billing_info.validate_vat).to be false
    end

    it "fails if unexpected error code received" do
      stub_request(:get, "https://ec.europa.eu/taxation_customs/vies/rest-api/ms/NL/vat/123123").to_return(status: 200, body: {userError: "MS_MAX_CONCURRENT_REQ"}.to_json)
      expect(billing_info).to receive(:stripe_data).and_return({"country" => "NL", "tax_id" => 123123}).at_least(:once)
      expect { billing_info.validate_vat }.to raise_error("Unexpected response from VAT service: MS_MAX_CONCURRENT_REQ")
    end
  end
end
