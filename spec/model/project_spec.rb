# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Project do
  subject(:project) { described_class.new }

  describe ".has_valid_payment_method?" do
    it "returns true when Stripe not enabled" do
      expect(Config).to receive(:stripe_secret_key).and_return(nil)
      expect(project.has_valid_payment_method?).to be true
    end

    it "returns false when no billing info" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      expect(project).to receive(:billing_info).and_return(nil)
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns false when no payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      bi = instance_double(BillingInfo, payment_methods: [])
      expect(project).to receive(:billing_info).and_return(bi)
      expect(project.has_valid_payment_method?).to be false
    end

    it "returns true when has valid payment method" do
      expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
      pm = instance_double(PaymentMethod)
      bi = instance_double(BillingInfo, payment_methods: [pm])
      expect(project).to receive(:billing_info).and_return(bi)
      expect(project.has_valid_payment_method?).to be true
    end
  end

  it "sets and gets feature flags" do
    described_class.feature_flag(:enable_postgres)
    project = described_class.create_with_id(name: "dummy-name")

    expect(project.get_enable_postgres).to be_nil
    project.set_enable_postgres("new-value")
    expect(project.get_enable_postgres).to eq "new-value"
  end
end
