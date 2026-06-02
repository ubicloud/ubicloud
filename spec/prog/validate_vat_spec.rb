# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::ValidateVat do
  subject(:vv) { described_class.new(Strand.new) }

  let(:billing_info) { BillingInfo.create(stripe_id: "cs_1234567890") }

  before do
    allow(vv).to receive(:billing_info).and_return(billing_info)
  end

  describe "#start" do
    it "pops after validating VAT" do
      expect(billing_info).to receive(:validate_vat).and_return(true)
      expect {
        expect { vv.start }.to exit({"msg" => "VAT validated"})
      }.to change(billing_info, :valid_vat).from(nil).to(true)
    end

    it "sends email to the customer cc'ing the notification address if VAT is invalid" do
      expect(billing_info).to receive(:email).and_return("customer@mail.com")
      expect(billing_info).to receive(:stripe_data).and_return({"tax_id" => "DE123456789"})
      expect(Config).to receive(:invalid_vat_notification_email).and_return("notify@ubicloud.com")
      expect(Util).to receive(:send_email).with("customer@mail.com", "Your VAT number could not be verified", hash_including(:greeting, body: include(include('"DE123456789"')), cc: "notify@ubicloud.com"))
      expect(billing_info).to receive(:validate_vat).and_return(false)
      expect {
        expect { vv.start }.to exit({"msg" => "VAT validated"})
      }.to change(billing_info, :valid_vat).from(nil).to(false)
    end

    it "falls back to the first project account when billing email is missing" do
      project = Project.create(name: "test", billing_info:)
      project.add_account(Account.create(email: "account@mail.com"))
      expect(billing_info).to receive(:email).and_return(nil)
      expect(billing_info).to receive(:stripe_data).and_return({"tax_id" => "DE123456789"})
      expect(Config).to receive(:invalid_vat_notification_email).and_return("notify@ubicloud.com")
      expect(Util).to receive(:send_email).with("account@mail.com", "Your VAT number could not be verified", hash_including(:greeting, :body, cc: "notify@ubicloud.com"))
      expect(billing_info).to receive(:validate_vat).and_return(false)
      expect {
        expect { vv.start }.to exit({"msg" => "VAT validated"})
      }.to change(billing_info, :valid_vat).from(nil).to(false)
    end

    it "does not send email if VAT is invalid but no customer email can be found" do
      project = Project.create(name: "test", billing_info:)
      expect(billing_info).to receive(:email).and_return(nil)
      expect(project.accounts).to be_empty
      expect(Util).not_to receive(:send_email)
      expect(billing_info).to receive(:validate_vat).and_return(false)
      expect {
        expect { vv.start }.to exit({"msg" => "VAT validated"})
      }.to change(billing_info, :valid_vat).from(nil).to(false)
    end
  end
end
