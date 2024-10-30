# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Invoice do
  subject(:invoice) { described_class.new(id: "50d5aae4-311c-843b-b500-77fbc7778050", begin_time: Time.now, end_time: Time.now, created_at: Time.now, content: {"cost" => 10, "subtotal" => 11, "credit" => 1, "discount" => 0, "resources" => []}, status: "unpaid") }

  let(:billing_info) { BillingInfo.create_with_id(stripe_id: "cs_1234567890") }

  before do
    allow(invoice).to receive(:reload)
    allow(invoice).to receive(:project).and_return(instance_double(Project, path: "/project/p1", accounts: []))
    allow(Config).to receive(:stripe_secret_key).and_return("secret_key")
  end

  describe ".send_failure_email" do
    it "sends failure email to accounts with billing permissions in addition to the provided billing email" do
      project = Project.create_with_id(name: "cool-project").tap { |p| p.associate_with_project(p) }
      accounts = (0..2).map { Account.create_with_id(email: "account#{_1}@example.com").tap { |a| a.associate_with_project(project) } }
      AccessPolicy.create_with_id(
        project_id: project.id,
        name: "default",
        body: {acls: [
          {subjects: accounts[0].hyper_tag_name, actions: "*", objects: project.hyper_tag_name},
          {subjects: accounts[1].hyper_tag_name, actions: "Vm:view", objects: project.hyper_tag_name},
          {subjects: accounts[2].hyper_tag_name, actions: "Project:billing", objects: project.hyper_tag_name}
        ]}
      )

      invoice = described_class.create_with_id(project_id: project.id, invoice_number: "001", begin_time: Time.now, end_time: Time.now, content: {
        "billing_info" => {"email" => "billing@example.com"},
        "resources" => [],
        "subtotal" => 0.0,
        "credit" => 0.0,
        "discount" => 0.0,
        "cost" => 0.0
      })

      invoice.send_failure_email([])

      expect(Mail::TestMailer.deliveries.first.to).to contain_exactly("billing@example.com", accounts[0].email, accounts[2].email)
    end
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
      invoice.content["billing_info"] = {"id" => billing_info.id, "email" => "customer@example.com"}
      invoice.content["cost"] = 0.4
      expect(invoice).to receive(:update).with(status: "below_minimum_threshold")
      expect(Clog).to receive(:emit).with("Invoice cost is less than minimum charge cost.").and_call_original
      expect(invoice.charge).to be true
      expect(Mail::TestMailer.deliveries.length).to eq 1
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
      expect(Mail::TestMailer.deliveries.length).to eq 1
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
      invoice.content["billing_info"] = {"id" => billing_info.id, "email" => "customer@example.com"}
      invoice.content["resources"] = [{"cost" => 4.3384, "line_items" => [{"cost" => 4.3384, "amount" => 5423.0, "duration" => 1, "location" => "global", "description" => "standard-2 GitHub Runner", "resource_type" => "GitHubRunnerMinutes", "resource_family" => "standard-2"}], "resource_id" => "ed0b26bf-53c4-82d2-9a00-21e5f05dc364", "resource_name" => "Daily Usage 2024-02-26"}]
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
      project = instance_double(Project)
      expect(project).to receive(:update).with(reputation: "verified")
      expect(invoice).to receive(:project).and_return(project)
      expect(invoice.charge).to be true
      expect(invoice.status).to eq("paid")
      expect(invoice.content["payment_method"]["id"]).to eq(payment_method2.id)
      expect(invoice.content["payment_intent"]).to eq("pi_1234567890")
      expect(Mail::TestMailer.deliveries.length).to eq 1
      expect(Mail::TestMailer.deliveries.first.attachments.length).to eq 1
    end

    it "does not update project reputation if cost is less than 5" do
      invoice.content["cost"] = 4
      invoice.content["billing_info"] = {"id" => billing_info.id}
      PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: "pm_1", order: 1)
      # rubocop:disable RSpec/VerifiedDoubles
      expect(Stripe::PaymentIntent).to receive(:create).and_return(double(Stripe::PaymentIntent, status: "succeeded", id: "pi_1234567890"))
      # rubocop:enable RSpec/VerifiedDoubles
      expect(invoice).to receive(:save).with(columns: [:status, :content])
      expect(invoice).to receive(:send_success_email)
      expect(invoice).not_to receive(:project)
      expect(invoice.charge).to be true
    end
  end
end
