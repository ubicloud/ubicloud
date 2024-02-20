# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

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

    it "sets and gets feature flags" do
      described_class.feature_flag(:dummy_flag)
      project = described_class.create_with_id(name: "dummy-name")

      expect(project.get_dummy_flag).to be_nil
      project.set_dummy_flag("new-value")
      expect(project.get_dummy_flag).to eq "new-value"
    end
  end

  describe ".soft_delete" do
    it "deletes github installations" do
      expect(project).to receive(:access_tags_dataset).and_return(instance_double(AccessTag, destroy: nil))
      expect(project).to receive(:access_policies_dataset).and_return(instance_double(AccessPolicy, destroy: nil))
      installation = instance_double(GithubInstallation, installation_id: 123)
      expect(installation).to receive(:destroy)
      expect(project).to receive(:github_installations).and_return([installation])
      app_client = instance_double(Octokit::Client)
      expect(Github).to receive(:app_client).and_return(app_client)
      expect(app_client).to receive(:delete_installation).with(123)
      expect(project).to receive(:update).with(visible: false)
      project.soft_delete
    end
  end
end
