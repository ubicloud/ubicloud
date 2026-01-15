# frozen_string_literal: true

require_relative "spec_helper"

require "json"

RSpec.describe Page do
  subject(:p) { described_class.create(tag: "dummy-tag") }

  describe ".group_by_vm_host" do
    it "groups pages by the VmHost they are related to" do
      expect(described_class.group_by_vm_host).to eq({})

      p1 = described_class.create(tag: "a")
      expect(described_class.group_by_vm_host).to eq({nil => [p1]})

      p2 = described_class.create(tag: "b", details: {"related_resources" => []})
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2]})

      p3 = described_class.create(tag: "c", details: {"related_resources" => [p2.ubid]})
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2, p3]})

      vmh = Prog::Vm::HostNexus.assemble("1.2.3.4").subject
      p4 = described_class.create(tag: "d", details: {"related_resources" => [vmh.ubid]})
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2, p3], vmh.ubid => [p4]})

      pj = Project.create(name: "test")
      vm = Prog::Vm::Nexus.assemble("a a", pj.id).subject
      p5 = described_class.create(tag: "e", details: {"related_resources" => [p3.ubid, vm.ubid]})
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2, p3, p5], vmh.ubid => [p4]})

      vm.update(vm_host_id: vmh.id)
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2, p3], vmh.ubid => [p4, p5]})

      p6 = described_class.create(tag: "f", details: {"related_resources" => [vm.nic.ubid]})
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2, p3], vmh.ubid => [p4, p5, p6]})

      gi = GithubInstallation.create(installation_id: 1, name: "t", type: "t")
      gr = Prog::Github::GithubRunnerNexus.assemble(gi, repository_name: "a", label: "ubicloud").subject
      p7 = described_class.create(tag: "g", details: {"related_resources" => [gr.ubid]})
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2, p3, p7], vmh.ubid => [p4, p5, p6]})

      gr.update(vm_id: vm.id)
      expect(described_class.order(:tag).group_by_vm_host).to eq({nil => [p1, p2, p3], vmh.ubid => [p4, p5, p6, p7]})
    end
  end

  describe "#trigger" do
    before do
      expect(Config).to receive(:pagerduty_key).and_return("dummy-key").at_least(:once)
      stub_request(:post, "https://events.pagerduty.com/v2/enqueue")
        .to_return(status: 200, body: {dedup_key: "dummy-dedup-key", message: "Event processed", status: "success"}.to_json, headers: {})
    end

    it "triggers a page in Pagerduty if key is present" do
      expect(p).to receive(:details).and_return({}).at_least(:once)
      p.trigger
    end

    it "triggers a page with custom_details" do
      expect(p).to receive(:details).and_return({"related_resources" => ["a410a91a-dc31-4119-9094-3c6a1fb49601"]}).at_least(:once)
      p.trigger
    end

    it "triggers a page with custom_details and log link" do
      expect(Config).to receive(:pagerduty_log_link).and_return("https://logviewer.com?q=<ubid>").at_least(:once)
      expect(p).to receive(:details).and_return({"related_resources" => ["a410a91a-dc31-4119-9094-3c6a1fb49601"]}).at_least(:once)
      p.trigger
    end
  end

  describe "#resolve" do
    it "resolves the page in Pagerduty if key is present" do
      expect(Config).to receive(:pagerduty_key).and_return("dummy-key").at_least(:once)
      stub_request(:post, "https://events.pagerduty.com/v2/enqueue")
        .to_return(status: 200, body: {dedup_key: "dummy-dedup-key", message: "Event processed", status: "success"}.to_json, headers: {})

      p.resolve
    end
  end
end
