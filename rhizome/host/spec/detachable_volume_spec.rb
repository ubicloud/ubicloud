# frozen_string_literal: true

require_relative "../lib/detachable_volume"
require "base64"
require "tmpdir"

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

  it "runs its backend as its owner, without network access when it has nothing to fetch" do
    expect(File).to receive(:write).with("/etc/systemd/system/#{service}", satisfy { |content|
      content.include?("Description=Vhost Block Backend Service for detachable volume #{id}") &&
        content.include?("User=user0") &&
        content.include?("ReadWritePaths=#{dir}") &&
        content.include?("PrivateNetwork=yes")
    })
    volume.vhost_backend_create_service_file
  end

  describe "#ensure_started" do
    it "removes what a failed layout or start left on the host, since nothing else would" do
      [:prep, :start].each do |failing|
        v = described_class.new(id, "user0", params)
        allow(v).to receive_messages(stop_service_if_loaded: nil, rm_if_exists: nil, prep: nil, start: nil)
        expect(v).to receive(failing).and_raise(RuntimeError, "#{failing} failed")
        expect(v).to receive(:delete)
        expect { v.ensure_started(kek, lay_out: true) }.to raise_error(RuntimeError, "#{failing} failed")
      end
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
    expect(volume).to receive(:_run_command).with("systemctl", "stop", service).ordered
    expect(FileUtils).to receive(:chown_R).with("user0", "user0", dir).ordered
    expect(volume).to receive(:vhost_backend_create_service_file).ordered
    expect(volume).to receive(:_run_command).with("systemctl", "daemon-reload").ordered
    expect(volume).to receive(:_run_command).with("systemctl", "stop", service).ordered
    expect(volume).to receive(:with_kek_pipe).with("#{dir}/kek.pipe", owner: "user0").and_yield("pipe")
    expect(volume).to receive(:_run_command).with("systemctl", "start", service)
    expect(volume).to receive(:write_kek_to_pipe).with("pipe", "a2V5")
    volume.vhost_backend_start(kek)
  end

  context "with its files in a directory" do
    around { |example|
      Dir.mktmpdir { |tmp|
        @dir = tmp
        example.run
      }
    }

    before { allow(volume.sp).to receive(:storage_dir).and_return(@dir) }

    def serve(reply)
      server = UNIXServer.new(volume.sp.rpc_socket_path)
      request = nil
      thread = Thread.new do
        conn = server.accept
        request = conn.gets
        conn.write(reply)
        conn.close
      end
      result = yield
      thread.join(5)
      server.close
      [result, request]
    end

    def lay_out_configs(volume_params)
      v = described_class.new(id, "user0", params.merge(volume_params))
      allow(v.sp).to receive(:storage_dir).and_return(@dir)
      allow(v).to receive(:write_through_device?).and_return(false)
      allow(FileUtils).to receive(:chown)
      v.vhost_backend_create_config({key: "ab" * 32, key2: "cd" * 32}, {"key" => Base64.strict_encode64("k" * 32)})
    end

    let(:remote) { {"remote_source" => {"address" => "[::1]:5500", "psk_identity" => "rs1", "encrypted_psk" => "cHNr", "autofetch" => true}} }

    it "stops a backend left running and lays the volume out afresh before starting it when asked to" do
      vol_dir = File.join(@dir, "vol")
      allow(volume.sp).to receive(:storage_dir).and_return(vol_dir)
      FileUtils.mkdir_p(vol_dir)
      File.write(File.join(vol_dir, "disk.raw"), "old")
      expect(volume).to receive(:_run_command).with("systemctl", "stop", service).ordered
      expect(volume).to receive(:prep).with(kek).ordered { expect(File).not_to exist(vol_dir) }
      expect(volume).to receive(:start).with(kek).ordered
      volume.ensure_started(kek, lay_out: true)
    end

    it "stops and removes its backend service and its files when deleted, without knowing its owner" do
      volume = described_class.new(id)
      vol_dir = File.join(@dir, "vol")
      allow(volume.sp).to receive(:storage_dir).and_return(vol_dir)
      FileUtils.mkdir_p(vol_dir)
      File.write(File.join(vol_dir, "disk.raw"), "data")
      expect(volume).to receive(:_run_command).with("systemctl", "stop", service)
      volume.delete
      expect(File).not_to exist(vol_dir)
    end

    it "stops its backend" do
      expect(volume).to receive(:_run_command).with("systemctl", "stop", service)
      volume.stop
    end

    it "asks its backend for the stripe counts" do
      result, request = serve(JSON.generate({"status" => {"stripes" => {"fetched" => 4, "source" => 8}}}) + "\n") {
        volume.stripes
      }
      expect(JSON.parse(request)).to eq({"command" => "status"})
      expect(result).to eq({"fetched" => 4, "source" => 8})
    end

    it "reports whether the volume is here, how far it has fetched, and whether that is done" do
      lay_out_configs(remote)
      serve(%({"status":{"stripes":{"fetched":3,"source":8}}}\n)) {
        expect(volume.status).to eq({"present" => true, "stripes" => {"fetched" => 3, "source" => 8}, "caught_up" => false})
      }
    end

    it "reports a volume that is not here without asking its backend" do
      expect(volume).not_to receive(:rpc)
      expect(volume.status).to eq({"present" => false, "stripes" => {}, "caught_up" => true})
    end

    it "lets its backend reach the network while its config reads from a remote source" do
      lay_out_configs(remote)
      expect(File).to receive(:write).with("/etc/systemd/system/#{service}", /PrivateNetwork=no/)
      volume.vhost_backend_create_service_file
    end

    it "is caught up once everything has been fetched from another host" do
      lay_out_configs(remote)
      expect(volume).to receive(:stripes).and_return({"fetched" => 8, "source" => 8})
      expect(volume).to be_caught_up
    end

    it "is not caught up while stripes from another host are outstanding, or when the backend cannot say" do
      lay_out_configs(remote)
      expect(volume.caught_up?({"fetched" => 1, "source" => 8})).to be false
      expect(volume.caught_up?({})).to be false
    end

    it "is not caught up on stripe counts it can't compare" do
      lay_out_configs(remote)
      expect(volume.caught_up?({"fetched" => 8})).to be false
    end

    it "is caught up when seeded from an image, however little of it has been read" do
      lay_out_configs({"image" => "seed"})
      expect(volume).not_to receive(:stripes)
      expect(volume).to be_caught_up
    end

    it "turns on catch-up once whatever uses the volume is serving" do
      _, request = serve("{}\n") { volume.start_autofetch }
      expect(JSON.parse(request)).to eq({"command" => "start_autofetch"})
    end

    it "says nothing when the socket is not there" do
      expect(volume.stripes).to eq({})
    end

    it "says nothing when the backend answers with something that is not JSON" do
      result, = serve("not json\n") { volume.rpc("status") }
      expect(result).to eq({})
    end
  end
end
