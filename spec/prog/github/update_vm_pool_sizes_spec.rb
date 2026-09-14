# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::UpdateVmPoolSizes do
  subject(:uvps) { described_class.new(Strand.new(prog: "Github::UpdateVmPoolSizes")) }

  describe "#wait" do
    it "decays stale stats and resizes matching pools" do
      fresh = GithubRunnerDemandStat.create(label: "ubicloud-standard-2", arch: "x64", ewma_rate: 2.0, ewma_hold_time: 100, last_arrival_at: Time.now)
      stale = GithubRunnerDemandStat.create(label: "ubicloud-standard-4", arch: "x64", ewma_rate: 2.0, ewma_hold_time: 100, last_arrival_at: Time.now - 120)

      pool = VmPool.create(
        size: 1, vm_size: "standard-4", boot_image: "img", location_id: Location::HETZNER_FSN1_ID,
        storage_size_gib: 86, arch: "x64",
      )

      expect { uvps.wait }.to nap(60)

      fresh.reload
      stale.reload
      expect(fresh.ewma_rate).to eq(2.0)
      expect(stale.ewma_rate).to be < 2.0

      pool.reload
      expect(pool.size).to eq(stale.target_size)
    end

    it "skips stats whose label is no longer recognized" do
      GithubRunnerDemandStat.create(label: "not-a-real-label", arch: "x64", ewma_rate: 5, ewma_hold_time: 5)

      expect { uvps.wait }.to nap(60)
    end

    it "naps even with no tracked stats" do
      expect { uvps.wait }.to nap(60)
    end
  end
end
