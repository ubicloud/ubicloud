# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe RemoteStorageServer do
  let(:source_vm) { create_archive_ready_vm }
  let(:source_volume) { VmStorageVolume.first(vm_id: source_vm.id) }
  let(:rss) {
    described_class.create(
      source_vm_storage_volume_id: source_volume.id, vm_host_id: create_vm_host.id,
      psk: "supersecretpsk", psk_identity: "ubiblk-rss", port: 5500,
    )
  }

  it "generates rs-prefixed ubids" do
    expect(described_class.generate_ubid.to_s).to start_with("rs")
  end

  it "encrypts the psk column at rest and round-trips it" do
    stored = DB[:remote_storage_server].where(id: rss.id).get(:psk)
    expect(stored).not_to eq("supersecretpsk")
    expect(rss.reload.psk).to eq("supersecretpsk")
  end

  it "resolves the source volume, vm and host" do
    expect(rss.source_vm_storage_volume).to eq(source_volume)
    expect(rss.vm).to eq(source_vm)
    expect(rss.vm_host).to eq(source_vm.vm_host)
  end

  it "builds the client-facing address from the host and port" do
    expect(rss.address).to end_with(":5500")
  end

  it "reads the source volume's disk.raw byte size over ssh" do
    expected_disk_file = File.join(source_volume.path, "disk.raw")
    expect(rss.vm_host.sshable).to receive(:_cmd).with("sudo stat -c %s #{expected_disk_file}").and_return("42949672960\n")
    expect(rss.source_disk_file_size).to eq(42949672960)
  end
end
