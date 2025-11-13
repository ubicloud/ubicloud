# frozen_string_literal: true

require_relative "../lib/slice_setup"
require_relative "../../common/lib/util"
require "fileutils"

return if ENV["RUN_E2E_TESTS"] != "1"
return if r("uname -r").to_i < 6

RSpec.describe SliceSetup do
  subject(:slice_setup) { described_class.new(slice_name) }

  let(:slice_name) { "slice_name.slice" }

  it "can prepare and purge a slice" do
    cpuset = "3-4"
    slice_setup.prep(cpuset)
    expect(File.exist?(slice_setup.systemd_service)).to be true

    # check that the slice is started
    expect(r("systemctl show -p ActiveState --value #{slice_name}")).to eq("active\n")

    # check that the cpuset.cpus.partition file contains "member"
    expect(File.read("/sys/fs/cgroup/#{slice_name}/cpuset.cpus.partition")).to eq("member\n")

    # check allowed cpus
    expect(File.read("/sys/fs/cgroup/#{slice_name}/cpuset.cpus")).to eq("#{cpuset}\n")

    slice_setup.purge

    # check that the slice is stopped & deleted
    expect(r("systemctl show -p ActiveState --value #{slice_name}")).to eq("inactive\n")
    expect(File.exist?(slice_setup.systemd_service)).to be false
  end

  it "doesn't fail if the slice doesn't exist" do
    slice_setup = described_class.new("nonexistent.slice")
    expect { slice_setup.purge }.not_to raise_error
  end
end
