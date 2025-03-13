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
  end
end
