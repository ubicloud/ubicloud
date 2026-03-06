# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::CheckDomainBlacklist do
  subject(:prog) { described_class.new(Strand.create(prog: "CheckDomainBlacklist", label: "start", stack: [{"subject_id" => account.id}])) }

  let(:account) { Account.create(email: "test@suspicious-domain.com") }
  let(:surbl_dns) { instance_double(Resolv::DNS) }

  before do
    allow(Resolv::DNS).to receive(:new).with(nameserver: "8.8.8.8").and_return(surbl_dns)
  end

  describe "#start" do
    it "pops if domain is not listed" do
      expect(surbl_dns).to receive(:getaddress).with("suspicious-domain.com.multi.surbl.org").and_raise(Resolv::ResolvError)

      expect { prog.start }.to exit({"msg" => "domain not listed in SURBL"})
    end

    it "naps for an hour and logs if access is blocked" do
      expect(surbl_dns).to receive(:getaddress).with("suspicious-domain.com.multi.surbl.org").and_return(Resolv::IPv4.create("127.0.0.1"))

      expect(Clog).to receive(:emit).with("SURBL access blocked", {surbl_access_blocked: {account_ubid: account.ubid, domain: "suspicious-domain.com"}})

      expect { prog.start }.to nap(60 * 60)
    end

    it "suspends account and logs when domain is on ABUSE list" do
      expect(surbl_dns).to receive(:getaddress).with("suspicious-domain.com.multi.surbl.org").and_return(Resolv::IPv4.create("127.0.0.64"))

      expect(Clog).to receive(:emit).with("Account email domain listed in SURBL", {account_surbl_hit: {account_ubid: account.ubid, domain: "suspicious-domain.com", lists: ["ABUSE"]}})
      expect(prog.account).to receive(:suspend)

      expect { prog.start }.to exit({"msg" => "domain check completed"})
    end

    it "suspends account and logs multiple lists when domain is on multiple lists" do
      expect(surbl_dns).to receive(:getaddress).with("suspicious-domain.com.multi.surbl.org").and_return(Resolv::IPv4.create("127.0.0.80"))

      expect(Clog).to receive(:emit).with("Account email domain listed in SURBL", {account_surbl_hit: {account_ubid: account.ubid, domain: "suspicious-domain.com", lists: ["MW", "ABUSE"]}})
      expect(prog.account).to receive(:suspend)

      expect { prog.start }.to exit({"msg" => "domain check completed"})
    end

    it "does not suspend account when result has no matching list bits" do
      expect(surbl_dns).to receive(:getaddress).with("suspicious-domain.com.multi.surbl.org").and_return(Resolv::IPv4.create("127.0.0.2"))

      expect(prog.account).not_to receive(:suspend)

      expect { prog.start }.to exit({"msg" => "domain check completed"})
    end
  end
end
