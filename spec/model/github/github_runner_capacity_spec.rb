# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubRunnerCapacity do
  let(:pool) { described_class["x64-standard"].update(total_cores: 100, total_hugepages_1g: 400, used_cores: 90, used_hugepages_1g: 100) }
  let(:spill) { described_class[described_class::SPILL].update(used_vcpus: 96, used_runners: 10) }
  let(:amounts) { {used_cores: 4, used_hugepages_1g: 16} }

  describe ".charge" do
    it "charges a pool within its utilization" do
      expect(described_class.charge(pool.name, amounts, described_class.metal_room(amounts, 95))).to be(true)
      expect(pool.reload.values.values_at(:used_cores, :used_hugepages_1g)).to eq([94, 116])
    end

    it "does not charge a pool past its utilization" do
      expect(described_class.charge(pool.name, amounts, described_class.metal_room(amounts, 93))).to be(false)
      expect(pool.reload.used_cores).to eq(90)
    end

    it "checks the hugepages too" do
      pool.update(used_hugepages_1g: 375)
      expect(described_class.charge(pool.name, amounts, described_class.metal_room(amounts, 97))).to be(false)
    end

    it "charges a pool without a condition" do
      expect(described_class.charge(pool.name, {used_cores: 20, used_hugepages_1g: 0})).to be(true)
      expect(pool.reload.used_cores).to eq(110)
    end

    it "charges the spill capacity within its configured limits" do
      expect(Config).to receive(:github_runner_aws_spill_vcpu_capacity).and_return(100).twice
      expect(Config).to receive(:github_runner_aws_spill_runner_capacity).and_return(50).twice
      expect(described_class.charge(spill.name, {used_vcpus: 4, used_runners: 1}, described_class.spill_room({used_vcpus: 4, used_runners: 1}))).to be(true)
      expect(described_class.charge(spill.name, {used_vcpus: 4, used_runners: 1}, described_class.spill_room({used_vcpus: 4, used_runners: 1}))).to be(false)
      expect(spill.reload.values.values_at(:used_vcpus, :used_runners)).to eq([100, 11])
    end
  end

  describe ".reconcile" do
    let(:installation) { GithubInstallation.create(installation_id: 789, name: "reconcile", type: "User") }

    def runner_with_vm(pool: nil, label: "ubicloud-standard-4")
      vm = create_vm(location_id: Location::GITHUB_RUNNERS_ID)
      GithubRunner.create(installation_id: installation.id, repository_name: "test-repo", label:, vm_id: vm.id, location_id: vm.location_id, capacity_pool: pool)
    end

    def counters(name)
      described_class[name].values.values_at(:total_cores, :total_hugepages_1g, :used_cores, :used_hugepages_1g, :used_vcpus, :used_runners)
    end

    before do
      create_vm_host(location_id: Location::GITHUB_RUNNERS_ID, total_cores: 48, total_cpus: 96, total_hugepages_1g: 375)
      runner_with_vm(pool: "x64-standard")
      runner_with_vm(pool: described_class::SPILL, label: "ubicloud-standard-30")
      runner_with_vm
    end

    it "corrects the drift of each pool from the hosts and the runners holding it" do
      described_class["x64-standard"].update(total_cores: 10, used_cores: 50, used_hugepages_1g: 16)
      described_class[described_class::SPILL].update(used_vcpus: 7, used_runners: 1)
      expect(Clog).to receive(:emit).with("github runner capacity drift", {github_runner_capacity_drift: {name: "x64-standard", total_cores: 38, total_hugepages_1g: 375, used_cores: -48}}).and_call_original
      expect(Clog).to receive(:emit).with("github runner capacity drift", {github_runner_capacity_drift: {name: described_class::SPILL, used_vcpus: 25}}).and_call_original

      described_class.reconcile

      expect(counters("x64-standard")).to eq([48, 375, 2, 16, 0, 0])
      expect(counters(described_class::SPILL)).to eq([0, 0, 0, 0, 32, 1])
      expect(described_class["x64-standard"].reconciled_at).not_to be_nil
    end

    it "keeps a reservation made between the snapshot and the correction" do
      described_class.reconcile
      rows = described_class.reconcile_rows
      expect(runner_with_vm.reserve_metal_capacity(100)).to be(true)

      described_class.reconcile(rows)

      expect(counters("x64-standard")).to eq([48, 375, 4, 32, 0, 0])
    end

    it "changes nothing on a second run" do
      described_class.reconcile
      expect(Clog).not_to receive(:emit)

      expect { described_class.reconcile }.not_to change { described_class.order(:name).map { it.values.except(:reconciled_at) } }
    end
  end

  describe ".refund" do
    it "stops the usage at zero" do
      described_class.refund(pool.name, {used_cores: 95, used_hugepages_1g: 4})
      expect(pool.reload.values.values_at(:used_cores, :used_hugepages_1g)).to eq([0, 96])
    end
  end
end
