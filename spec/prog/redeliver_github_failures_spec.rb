# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RedeliverGithubFailures do
  subject(:rgf) {
    described_class.new(Strand.new(prog: "RedeliverGithubFailures", stack: [{"last_check_at" => "2023-10-19 22:27:47 +0000"}]))
  }

  describe "#wait" do
    it "redelivers failed deliveries and naps" do
      expect(Time).to receive(:now).and_return("2023-10-19 23:27:47 +0000").at_least(:once)
      expect(Github).to receive(:redeliver_failed_deliveries).with(Time.utc(2023, 10, 19, 22, 27, 47))
      expect(rgf.strand).to receive(:save_changes)
      expect {
        expect { rgf.wait }.to nap(2 * 60)
      }.to change { rgf.strand.stack.first["last_check_at"] }.from("2023-10-19 22:27:47 +0000").to("2023-10-19 23:27:47 +0000")
    end
  end
end
