# frozen_string_literal: true

# CloudHypervisor::Version reads /etc/os-release at load time to pick the
# supported version set; stub it so the suite also runs on non-Ubuntu dev
# boxes (CI runs on Ubuntu).
if File.exist?("/etc/os-release")
  real_read = File.method(:read)
  File.define_singleton_method(:read) do |path, **kw|
    (path == "/etc/os-release") ? "ID=ubuntu\nVERSION_ID=\"22.04\"\n" : real_read.call(path, **kw)
  end
end

begin
  require_relative "../lib/stale_vm_cleaner"
ensure
  File.define_singleton_method(:read, real_read) if real_read
end

RSpec.describe StaleVmCleaner do
  subject(:cleaner) { described_class.new(expected_vm_names: expected_vm_names, expected_slice_names: expected_slice_names) }

  let(:expected_vm_names) { ["vmabcdef"] }
  let(:expected_slice_names) { ["standard_vmabcdef.slice"] }

  describe "naming regexes" do
    it "matches valid vm inhost names" do
      expect(described_class::VM_NAME_RE).to match("vmabcdef")
      expect(described_class::VM_NAME_RE).to match("vm132435")
    end

    it "rejects names that are not ours" do
      expect(described_class::VM_NAME_RE).not_to match("vmabcd")       # too short
      expect(described_class::VM_NAME_RE).not_to match("vmabcdefg")    # too long
      expect(described_class::VM_NAME_RE).not_to match("vmabcdef-")    # invalid char
      expect(described_class::VM_NAME_RE).not_to match("notavm123456") # wrong prefix
      expect(described_class::VM_NAME_RE).not_to match("vmi12345")     # 'i' not in alphabet
    end

    it "matches valid slice unit names" do
      expect(described_class::SLICE_NAME_RE).to match("standard_vmabcdef.slice")
      expect(described_class::SLICE_NAME_RE).to match("burstable_vm132435.slice")
    end

    it "rejects slice units that are not ours" do
      expect(described_class::SLICE_NAME_RE).not_to match("system.slice")
      expect(described_class::SLICE_NAME_RE).not_to match("standard.slice")
      expect(described_class::SLICE_NAME_RE).not_to match("standard_vmabcd.slice")
    end
  end

  describe ".dir_children" do
    it "returns empty list when the directory does not exist" do
      expect(described_class.dir_children("/does/not/exist")).to eq([])
    end
  end

  describe ".vm_names_from_vm_dir" do
    it "returns only vm-like entries" do
      expect(described_class).to receive(:dir_children).with("/vm").and_return(["vmabcdef", "vm123456", "images", "other"])
      expect(described_class.vm_names_from_vm_dir).to eq(["vmabcdef", "vm123456"])
    end
  end

  describe ".slice_names_from_unit_dir" do
    it "returns only our slice entries" do
      expect(described_class).to receive(:dir_children).with("/etc/systemd/system").and_return(["standard_vmabcdef.slice", "sshd.service", "standard.slice"])
      expect(described_class.slice_names_from_unit_dir).to eq(["standard_vmabcdef.slice"])
    end
  end

  describe "#stale_vm_names" do
    it "returns vm names on host that are not expected" do
      expect(described_class).to receive(:vm_names_from_vm_dir).and_return(["vmabcdef", "vm999999", "vm000000"])
      expect(cleaner.stale_vm_names).to eq(["vm999999", "vm000000"])
    end
  end

  describe "#stale_slice_names" do
    it "returns slice units on host that are not expected" do
      expect(described_class).to receive(:slice_names_from_unit_dir).and_return(["standard_vmabcdef.slice", "burstable_vm111111.slice"])
      expect(cleaner.stale_slice_names).to eq(["burstable_vm111111.slice"])
    end
  end

  describe "#clean" do
    it "purges stale vms and slices and reports what it cleaned" do
      expect(cleaner).to receive(:stale_vm_names).and_return(["vm999999"])
      expect(cleaner).to receive(:stale_slice_names).and_return(["burstable_vm111111.slice"])

      expect(cleaner).to receive(:purge_vm).with("vm999999")
      expect(cleaner).to receive(:purge_slice).with("burstable_vm111111.slice")

      expect(cleaner.clean).to eq({"vms" => ["vm999999"], "slices" => ["burstable_vm111111.slice"]})
    end

    it "does nothing when there is nothing stale" do
      expect(cleaner).to receive(:stale_vm_names).and_return([])
      expect(cleaner).to receive(:stale_slice_names).and_return([])

      expect(cleaner).not_to receive(:purge_vm)
      expect(cleaner).not_to receive(:purge_slice)

      expect(cleaner.clean).to eq({"vms" => [], "slices" => []})
    end
  end

  describe "#purge_vm" do
    it "stops unit, dnsmasq and runs VmSetup#purge with prep.json params" do
      expect(cleaner).to receive(:_run_command).with("systemctl", "stop", "vm999999")
      expect(cleaner).to receive(:_run_command).with("systemctl", "stop", "vm999999-dnsmasq")
      expect(VmPath).to receive(:new).with("vm999999").and_return(instance_double(VmPath, prep_json: "/vm/vm999999/prep.json"))
      expect(File).to receive(:read).with("/vm/vm999999/prep.json").and_return('{"ch_version": "46.0", "hugepages": false}')
      expect_vm_setup_purge("vm999999", hugepages: false, ch_version: "46.0")
      cleaner.purge_vm("vm999999")
    end

    it "defaults params when prep.json is missing" do
      expect(cleaner).to receive(:_run_command).with("systemctl", "stop", "vm999999")
      expect(cleaner).to receive(:_run_command).with("systemctl", "stop", "vm999999-dnsmasq")
      expect(VmPath).to receive(:new).with("vm999999").and_return(instance_double(VmPath, prep_json: "/vm/vm999999/prep.json"))
      expect(File).to receive(:read).and_raise(Errno::ENOENT)
      expect_vm_setup_purge("vm999999", hugepages: true, ch_version: nil, firmware_version: nil)
      cleaner.purge_vm("vm999999")
    end

    it "tolerates a unit that is not loaded" do
      expect(cleaner).to receive(:_run_command).with("systemctl", "stop", "vm999999").and_raise(CommandFail.new("err", "", "Failed to stop vm999999.service: Unit vm999999.service not loaded."))
      expect(cleaner).to receive(:_run_command).with("systemctl", "stop", "vm999999-dnsmasq")
      expect(File).to receive(:read).and_raise(Errno::ENOENT)
      expect_vm_setup_purge("vm999999", hugepages: true, ch_version: nil, firmware_version: nil)
      cleaner.purge_vm("vm999999")
    end
  end

  describe "#purge_slice" do
    it "purges the slice via SliceSetup" do
      slice_setup = instance_double(SliceSetup)
      expect(SliceSetup).to receive(:new).with("burstable_vm111111.slice").and_return(slice_setup)
      expect(slice_setup).to receive(:purge)
      cleaner.purge_slice("burstable_vm111111.slice")
    end
  end

  def expect_vm_setup_purge(name, hugepages:, ch_version: nil, firmware_version: nil)
    vm_setup = instance_double(VmSetup)
    expect(VmSetup).to receive(:new).with(name, hash_including(hugepages: hugepages, ch_version: ch_version, firmware_version: firmware_version)).and_return(vm_setup)
    expect(vm_setup).to receive(:purge)
  end
end
