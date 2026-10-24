# frozen_string_literal: true

require_relative "../lib/detachable_volume"

RSpec.describe DetachableVolume do
  subject(:volume) { described_class.new(id, "user0", params) }

  let(:id) { "dv#{"0" * 24}" }
  let(:dir) { "/var/storage/detachable/#{id}" }
  let(:service) { "#{id}-storage.service" }
  let(:params) { {"device_id" => "dvdev", "size_gib" => 2, "vhost_block_backend_version" => "v0.5.1"} }
  let(:kek) { {"key" => "a2V5"} }

  it "lives in a directory of its own, whatever its owner" do
    expect(volume.storage_dir).to eq(dir)
    expect(volume.storage_root).to eq(dir)
    expect(volume.disk_file).to eq("#{dir}/disk.raw")
    expect(volume.vhost_sock).to eq("#{dir}/vhost.sock")
    expect(volume.sp.kek_pipe).to eq("#{dir}/kek.pipe")
  end

  it "has a backend service named after the volume, not its owner" do
    expect(volume.vhost_user_block_service).to eq(service)
  end

  it "refuses an id that could reach outside the volume root" do
    expect { described_class.new("../../..").storage_dir }.to raise_error(ArgumentError, 'invalid detachable volume id: "../../.."')
  end

  it "runs its backend as its owner, with network access to fetch from a remote source" do
    expect(File).to receive(:write).with("/etc/systemd/system/#{service}", satisfy { |content|
      content.include?("Description=Vhost Block Backend Service for detachable volume #{id}") &&
        content.include?("User=user0") &&
        content.include?("ReadWritePaths=#{dir}") &&
        content.include?("PrivateNetwork=no")
    })
    volume.vhost_backend_create_service_file
  end

  describe "#ensure_started" do
    it "lays the volume out afresh before starting it when asked to" do
      expect(volume).to receive(:rm_if_exists).with(dir).ordered
      expect(volume).to receive(:prep).with(kek).ordered
      expect(volume).to receive(:start).with(kek).ordered
      volume.ensure_started(kek, lay_out: true)
    end

    it "only starts a volume whose data is already here" do
      expect(volume).not_to receive(:prep)
      expect(volume).to receive(:start).with(kek)
      volume.ensure_started(kek, lay_out: false)
    end

    it "refuses a backend without config v2" do
      [nil, "v0.2.2"].each do |version|
        v = described_class.new(id, "user0", params.merge("vhost_block_backend_version" => version))
        expect { v.ensure_started(kek, lay_out: true) }.to raise_error(RuntimeError, "detachable volumes need a vhost block backend with config v2")
      end
    end
  end

  it "hands itself and its service to its current owner when started" do
    expect(volume).to receive(:stop_service_if_loaded).with(service).ordered
    expect(FileUtils).to receive(:chown_R).with("user0", "user0", dir).ordered
    expect(volume).to receive(:vhost_backend_create_service_file).ordered
    expect(volume).to receive(:_run_command).with("systemctl", "daemon-reload").ordered
    expect(volume).to receive(:_run_command).with("systemctl", "stop", service).ordered
    expect(volume).to receive(:rm_if_exists).twice
    expect(volume).to receive(:with_kek_pipe).with("#{dir}/kek.pipe", owner: "user0").and_yield("pipe")
    expect(volume).to receive(:_run_command).with("systemctl", "start", service)
    expect(volume).to receive(:write_kek_to_pipe).with("pipe", "a2V5")
    volume.vhost_backend_start(kek)
  end

  it "stops and removes its backend service and its files when deleted, without knowing its owner" do
    volume = described_class.new(id)
    expect(volume).to receive(:stop_service_if_loaded).with(service)
    expect(volume).to receive(:rm_if_exists).with("/etc/systemd/system/#{service}")
    expect(volume).to receive(:rm_if_exists).with("#{dir}/vhost.sock")
    expect(volume).to receive(:rm_if_exists).with(dir)
    volume.delete
  end
end
