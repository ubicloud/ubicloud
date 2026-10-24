# frozen_string_literal: true

require_relative "../lib/storage_path"

RSpec.describe StoragePath do
  it "keeps a VM disk under its VM, on the default device" do
    sp = described_class.new("vm123456", DEFAULT_STORAGE_DEVICE, 1)
    expect(sp.storage_dir).to eq("/var/storage/vm123456/1")
    expect(sp.vhost_backend_service).to eq("vm123456-1-storage.service")
  end

  it "keeps a VM disk on another device under that device" do
    expect(described_class.new("vm123456", "nvme1", 0).storage_dir).to eq("/var/storage/devices/nvme1/vm123456/0")
  end

  describe ".detachable" do
    let(:id) { "dv#{"0" * 24}" }
    let(:sp) { described_class.detachable(id) }

    it "keeps a detachable volume in a directory of its own" do
      expect(sp.storage_root).to eq("/var/storage/detachable/#{id}")
      expect(sp.storage_dir).to eq("/var/storage/detachable/#{id}")
      expect(sp.disk_file).to eq("/var/storage/detachable/#{id}/disk.raw")
      expect(sp.vhost_backend_secrets_config).to eq("/var/storage/detachable/#{id}/vhost-backend-secrets.conf")
    end

    it "names its backend service after the volume" do
      expect(sp.vhost_backend_service).to eq("#{id}-storage.service")
    end

    it "refuses an id that could reach outside the volume root" do
      expect { described_class.detachable("../../..") }.to raise_error(ArgumentError, 'invalid detachable volume id: "../../.."')
    end
  end
end
