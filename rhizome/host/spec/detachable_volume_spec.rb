# frozen_string_literal: true

require_relative "../lib/detachable_volume"
require "base64"
require "tmpdir"

RSpec.describe DetachableVolume do
  subject(:volume) { described_class.new(id, ubiblk_version: "v0.5.1") }

  let(:id) { "dv#{"0" * 24}" }
  let(:kek) { Base64.strict_encode64("k" * 32) }

  it "derives every path from the volume id" do
    expect(volume.dir).to eq("/var/storage/detachable/#{id}")
    expect(volume.disk_file).to eq("/var/storage/detachable/#{id}/disk.raw")
    expect(volume.metadata_file).to eq("/var/storage/detachable/#{id}/metadata")
    expect(volume.vhost_sock).to eq("/var/storage/detachable/#{id}/vhost.sock")
    expect(volume.rpc_sock).to eq("/var/storage/detachable/#{id}/rpc.sock")
    expect(volume.kek_pipe_path).to eq("/var/storage/detachable/#{id}/kek.pipe")
    expect(volume.unit).to eq("dv-#{id}-storage.service")
  end

  it "only takes a volume id, so the id cannot reach outside the volume root" do
    expect { described_class.new("../../..") }.to raise_error(ArgumentError, 'invalid volume id: "../../.."')
  end

  it "needs a ubiblk version only to run the backend" do
    expect { described_class.new(id).write_unit("user0") }
      .to raise_error(RuntimeError, "running the backend needs a ubiblk version")
  end

  it "is present once its config is" do
    expect(File).to receive(:exist?).with(volume.main_conf).and_return(true)
    expect(volume).to exist
  end

  describe "#create" do
    around { |example|
      Dir.mktmpdir { |dir|
        @dir = dir
        example.run
      }
    }

    before do
      volume.instance_variable_set(:@dir, @dir)
      allow(FileUtils).to receive(:chown)
      allow(File).to receive(:chmod)
      allow(volume).to receive(:init_metadata)
    end

    it "makes the disk sparse at the requested size and writes the configs" do
      volume.create(device_id: "cldata", size_gib: 2, kek: kek, wrapped_xts: "wrapped", source: {"type" => "new", "image" => "seed"},
        unix_user: "user0")
      expect(File.size(File.join(@dir, "disk.raw"))).to eq(2 * 1024 * 1024 * 1024)
      expect(PerfectTOML.load_file(File.join(@dir, "vhost-backend.conf"))).to eq({
        "include" => ["vhost-backend-stripe-source.conf", "vhost-backend-secrets.conf"],
        "device" => {
          "data_path" => "#{@dir}/disk.raw",
          "vhost_socket" => "#{@dir}/vhost.sock",
          "rpc_socket" => "#{@dir}/rpc.sock",
          "device_id" => "cldata",
          "track_written" => true,
          "metadata_path" => "#{@dir}/metadata",
        },
        "tuning" => {"num_queues" => 1, "queue_size" => 64, "seg_size_max" => 65536, "seg_count_max" => 4, "poll_timeout_us" => 1000, "write_through" => false},
        "encryption" => {"xts_key" => {"ref" => "xts-key"}},
      })
      expect(PerfectTOML.load_file(File.join(@dir, "vhost-backend-stripe-source.conf"))).to eq({
        "stripe_source" => {"type" => "raw", "image_path" => "/var/storage/images/seed.raw", "copy_on_read" => true},
      })
      expect(PerfectTOML.load_file(File.join(@dir, "vhost-backend-secrets.conf"))).to eq({"secrets" => {
        "xts-key" => {"encoding" => "base64", "source" => {"inline" => "wrapped"}, "encrypted_by" => {"ref" => "kek"}},
        "kek" => {"encoding" => "base64", "source" => {"file" => "#{@dir}/kek.pipe"}},
      }})
    end

    it "puts the main config in place only once the metadata is initialised, so a killed layout is not taken for a volume" do
      expect(volume).to receive(:init_metadata) { expect(volume).not_to exist }
      volume.create(device_id: "cldata", size_gib: 1, kek: kek, wrapped_xts: "w", source: nil, unix_user: "user0")
      expect(volume).to exist
      expect(File).not_to exist(volume.staged_main_conf)
    end

    it "lays a volume out afresh over whatever a killed layout left" do
      File.write(File.join(@dir, "leftover"), "x")
      File.write(volume.staged_main_conf, "half")
      volume.create(device_id: "cldata", size_gib: 1, kek: kek, wrapped_xts: "w", source: nil, unix_user: "user0")
      expect(File).not_to exist(File.join(@dir, "leftover"))
      expect(PerfectTOML.load_file(volume.main_conf).dig("device", "device_id")).to eq("cldata")
    end

    it "initialises the metadata, which tracks what is written and fetched" do
      expect(volume).to receive(:init_metadata).with(kek, "user0")
      volume.create(device_id: "cldata", size_gib: 1, kek: kek, wrapped_xts: "w", source: {"type" => "new", "image" => "seed"},
        unix_user: "user0")
      expect(File.size(File.join(@dir, "metadata"))).to eq(8 * 1024 * 1024)
    end

    it "writes no stripe source for a volume with nothing to read from" do
      volume.create(device_id: "cldata", size_gib: 1, kek: kek, wrapped_xts: "w", source: nil, unix_user: "user0")
      expect(File).not_to exist(File.join(@dir, "vhost-backend-stripe-source.conf"))
      expect(PerfectTOML.load_file(File.join(@dir, "vhost-backend.conf"))["include"]).to eq(["vhost-backend-secrets.conf"])
    end

    it "removes a half-laid-out volume when laying it out fails, so a retry starts over" do
      volume.instance_variable_set(:@dir, File.join(@dir, id))
      expect(volume).to receive(:init_metadata).and_raise(RuntimeError, "init-metadata failed")
      expect {
        volume.create(device_id: "cldata", size_gib: 1, kek: kek, wrapped_xts: "w", source: {"type" => "new", "image" => "seed"}, unix_user: "user0")
      }.to raise_error(RuntimeError, "init-metadata failed")
      expect(File).not_to exist(File.join(@dir, id))
    end
  end

  describe "#stripe_source_toml" do
    it "reads a new or raw volume through to the seed image" do
      %w[new raw].each do |type|
        expect(PerfectTOML.parse(volume.stripe_source_toml({"type" => type, "image" => "seed-image"}))).to eq({
          "stripe_source" => {"type" => "raw", "image_path" => "/var/storage/images/seed-image.raw", "copy_on_read" => true},
        })
      end
    end

    it "pulls from another host, fetching in the background only when asked to" do
      toml = volume.stripe_source_toml({"type" => "remote", "address" => "[fd00::2]:9000", "psk_identity" => "rs1", "autofetch" => false})
      expect(PerfectTOML.parse(toml)).to eq({"stripe_source" => {
        "type" => "remote",
        "address" => "[fd00::2]:9000",
        "autofetch" => false,
        "connections" => 16,
        "psk" => {"identity" => "rs1", "secret" => {"ref" => "remote-psk"}},
      }})
    end

    it "refuses a source it does not know" do
      expect { volume.stripe_source_toml({"type" => "magic"}) }
        .to raise_error(RuntimeError, "unsupported stripe source magic")
    end
  end

  describe "#write_configs" do
    around { |example|
      Dir.mktmpdir { |dir|
        @dir = dir
        example.run
      }
    }

    before do
      volume.instance_variable_set(:@dir, @dir)
      allow(FileUtils).to receive(:chown)
    end

    it "carries the pre-shared key for a remote source" do
      volume.write_configs(source: {"type" => "remote", "address" => "[::1]:5500", "psk_identity" => "rs1", "wrapped_psk" => "psk", "autofetch" => true},
        wrapped_xts: "w", device_id: "cldata", unix_user: "user0")
      expect(PerfectTOML.load_file(volume.secrets_conf).dig("secrets", "remote-psk"))
        .to eq({"encoding" => "base64", "source" => {"inline" => "psk"}, "encrypted_by" => {"ref" => "kek"}})
    end

    it "carries nothing extra for a local source" do
      volume.write_configs(source: {"type" => "new", "image" => "seed"}, wrapped_xts: "w", device_id: "cldata", unix_user: "user0")
      expect(PerfectTOML.load_file(volume.secrets_conf)["secrets"].keys).to eq(["xts-key", "kek"])
    end
  end

  describe "#ensure_started" do
    it "lays a new volume out before starting it" do
      expect(volume).to receive(:exist?).and_return(false)
      expect(volume).to receive(:create).with(device_id: "cldata", size_gib: 2, kek: kek, wrapped_xts: "w", source: {"type" => "new", "image" => "seed-image"},
        unix_user: "user0").ordered
      expect(volume).to receive(:start).with(kek, "user0", slice: nil).ordered
      volume.ensure_started(kek: kek, unix_user: "user0", device_id: "cldata", slice: nil, size_gib: 2, wrapped_xts: "w",
        source: {"type" => "new", "image" => "seed-image"})
    end

    it "only starts a volume that is already here" do
      expect(volume).to receive(:exist?).and_return(true)
      expect(volume).not_to receive(:create)
      expect(volume).to receive(:start).with(kek, "user0", slice: "example.slice")
      volume.ensure_started(kek: kek, unix_user: "user0", device_id: "cldata", slice: "example.slice", size_gib: 2, wrapped_xts: "w", source: nil)
    end
  end

  describe "#start" do
    before do
      allow(volume).to receive_messages(stop: nil, write_unit: nil, r: nil, take_ownership: nil)
      allow(FileUtils).to receive(:rm_f)
      allow(volume).to receive(:with_kek_pipe).and_yield("/pipe")
      allow(volume).to receive(:write_kek_to_pipe)
    end

    it "takes ownership first, because a volume can come back under another user" do
      expect(volume).to receive(:take_ownership).with("user3").ordered
      expect(volume).to receive(:write_unit).with("user3", nil).ordered
      expect(File).to receive(:socket?).and_return(true)
      volume.start(kek, "user3")
    end

    it "runs the backend in the slice it is given" do
      expect(volume).to receive(:write_unit).with("user3", "example.slice")
      expect(File).to receive(:socket?).and_return(true)
      volume.start(kek, "user3", slice: "example.slice")
    end

    it "streams the KEK through a fifo rather than putting it on a command line" do
      expect(volume).to receive(:with_kek_pipe).with(volume.kek_pipe_path, owner: "user0").and_yield("/pipe")
      expect(volume).to receive(:write_kek_to_pipe).with("/pipe", kek)
      expect(File).to receive(:socket?).and_return(true)
      volume.start(kek, "user0")
    end

    it "keeps waiting until the backend opens its socket" do
      expect(File).to receive(:socket?).with(volume.vhost_sock).twice.and_return(false, true)
      volume.start(kek, "user0")
    end

    it "gives up when the backend never opens its socket" do
      stub_const("DetachableVolume::START_TIMEOUT", 0)
      expect(File).to receive(:socket?).at_least(:once).and_return(false)
      expect { volume.start(kek, "user0") }
        .to raise_error(RuntimeError, "ubiblk never opened #{volume.vhost_sock}")
    end
  end

  describe "#take_ownership" do
    it "hands the whole volume to the user it is starting under" do
      expect(FileUtils).to receive(:chown_R).with("user3", "user3", volume.dir)
      volume.take_ownership("user3")
    end
  end

  describe "#write_unit" do
    let(:unit) {
      <<~UNIT
        [Unit]
        Description=Detachable volume #{id}
        After=network.target

        [Service]
        SLICE
        Environment=RUST_LOG=info
        ExecStart=/opt/vhost-block-backend/v0.5.1/vhost-backend --config /var/storage/detachable/#{id}/vhost-backend.conf
        Restart=no
        User=user0
        Group=user0
        NoNewPrivileges=true
        ProtectSystem=full
        ReadWritePaths=/var/storage/detachable/#{id}
        PrivateTmp=true
        ProtectKernelModules=true
        ProtectKernelTunables=true
        ProtectControlGroups=true
        RestrictNamespaces=true
        RestrictSUIDSGID=yes
        MemoryDenyWriteExecute=yes

        [Install]
        WantedBy=multi-user.target
      UNIT
    }

    it "runs the backend as its user, with the volume its only writable path" do
      expect(volume).to receive(:safe_write_to_file).with("/etc/systemd/system/#{volume.unit}", unit.sub("SLICE", ""))
      volume.write_unit("user0")
    end

    it "puts the backend in a slice when given one" do
      expect(volume).to receive(:safe_write_to_file).with("/etc/systemd/system/#{volume.unit}", unit.sub("SLICE", "Slice=example.slice"))
      volume.write_unit("user0", "example.slice")
    end
  end

  describe "#stop and #destroy" do
    it "stops the unit" do
      expect(volume).to receive(:_run_command).with("systemctl", "stop", volume.unit)
      volume.stop
    end

    it "does not mind a unit that is not running" do
      expect(volume).to receive(:_run_command).with("systemctl", "stop", volume.unit).and_raise(CommandFail.new("no", "", ""))
      expect(volume.stop).to be_nil
    end

    it "takes the unit and the bytes with it" do
      expect(volume).to receive(:stop)
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/#{volume.unit}")
      expect(FileUtils).to receive(:rm_rf).with(volume.dir)
      volume.destroy
    end
  end

  describe "the ubiblk control socket" do
    around { |example|
      Dir.mktmpdir { |dir|
        @dir = dir
        example.run
      }
    }

    def serve(reply)
      volume.instance_variable_set(:@dir, @dir)
      path = volume.rpc_sock
      server = UNIXServer.new(path)
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

    it "asks for the stripe counts" do
      result, request = serve(JSON.generate({"status" => {"stripes" => {"fetched" => 4, "source" => 8}}}) + "\n") {
        volume.stripes
      }
      expect(JSON.parse(request)).to eq({"command" => "status"})
      expect(result).to eq({"fetched" => 4, "source" => 8})
    end

    it "reports whether the volume is here, how far it has fetched, and whether that is done" do
      expect(volume).to receive_messages(exist?: true, remote_source?: true)
      serve(%({"status":{"stripes":{"fetched":3,"source":8}}}\n)) {
        expect(volume.status).to eq({"present" => true, "stripes" => {"fetched" => 3, "source" => 8}, "caught_up" => false})
      }
    end

    it "reports a volume that is not here without asking its backend" do
      expect(volume).not_to receive(:rpc)
      expect(volume.status).to eq({"present" => false, "stripes" => {}, "caught_up" => true})
    end

    it "is caught up once everything has been fetched from another host" do
      expect(volume).to receive_messages(remote_source?: true, stripes: {"fetched" => 8, "source" => 8})
      expect(volume).to be_caught_up
    end

    it "is not caught up while stripes from another host are outstanding" do
      expect(volume).to receive_messages(remote_source?: true, stripes: {"fetched" => 1, "source" => 8})
      expect(volume).not_to be_caught_up
    end

    it "is not caught up when the backend cannot say, as when it is stopped" do
      expect(volume).to receive_messages(remote_source?: true, stripes: {})
      expect(volume).not_to be_caught_up
    end

    it "is caught up when seeded from an image, however little of it has been read" do
      expect(volume).to receive(:remote_source?).and_return(false)
      expect(volume).not_to receive(:stripes)
      expect(volume).to be_caught_up
    end

    it "says nothing when the socket is not there" do
      volume.instance_variable_set(:@dir, @dir)
      expect(volume.stripes).to eq({})
    end

    it "says nothing when the backend answers with something that is not JSON" do
      result, = serve("not json\n") { volume.rpc("status") }
      expect(result).to eq({})
    end
  end

  describe "#remote_source?" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    before { allow(volume).to receive(:source_conf).and_return(File.join(@dir, "source.conf")) }

    it "is true for a volume that reads through to another host" do
      File.write(volume.source_conf, volume.stripe_source_toml({"type" => "remote", "address" => "[::1]:5500", "psk_identity" => "rs1", "autofetch" => true}))
      expect(volume.remote_source?).to be true
    end

    it "is false for one seeded from an image, and for one with no source at all" do
      expect(volume.remote_source?).to be false
      File.write(volume.source_conf, volume.stripe_source_toml({"type" => "new", "image" => "seed"}))
      expect(volume.remote_source?).to be false
    end
  end

  describe "#serve" do
    it "stops the backend and runs ubiblk's remote stripe server on the volume, with the KEK through its pipe" do
      expect(volume).to receive(:stop).ordered
      expect(volume).to receive(:run_with_kek_pipe).ordered { |cmd, kek_pipe:, kek_content:, env:, stdin:|
        expect(cmd).to eq(["/opt/vhost-block-backend/v0.5.1/remote-stripe-server", "-f", volume.main_conf, "--listen-config", "/dev/stdin"])
        expect(kek_pipe).to eq(volume.kek_pipe_path)
        expect(kek_content).to eq(kek)
        expect(env).to eq({"RUST_LOG" => "info"})
        expect(stdin).to include(%(address = "0.0.0.0:5500"), %(identity = "rs1"))
      }
      volume.serve(port: 5500, psk: "cHNr", psk_identity: "rs1", kek: kek, server_version: "v0.5.1")
    end

    it "needs a ubiblk with the remote stripe server" do
      expect { volume.serve(port: 5500, psk: "cHNr", psk_identity: "rs1", kek: kek, server_version: "v0.4.2") }
        .to raise_error(RuntimeError, "remote-stripe-server requires vhost block backend v0.5.0 or later")
    end
  end

  describe "#drop_source" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    before do
      volume.instance_variable_set(:@dir, @dir)
      allow(FileUtils).to receive(:chown)
      allow(volume).to receive(:init_metadata)
    end

    it "forgets the host it caught up from, keeping everything else" do
      volume.create(source: {"type" => "remote", "address" => "[::1]:5500", "psk_identity" => "rs1", "wrapped_psk" => "cHNr", "autofetch" => true},
        size_gib: 1, kek: kek, wrapped_xts: "eHRz", device_id: "cldata", unix_user: "user0")
      volume.drop_source
      main = PerfectTOML.load_file(volume.main_conf)
      expect(main["include"]).to eq(["vhost-backend-secrets.conf"])
      expect(main.dig("device", "metadata_path")).to eq(volume.metadata_file)
      expect(File).not_to exist(volume.source_conf)
      secrets = PerfectTOML.load_file(volume.secrets_conf)["secrets"]
      expect(secrets.keys).to contain_exactly("xts-key", "kek")
      expect(secrets.dig("xts-key", "source", "inline")).to eq("eHRz")
    end

    it "leaves a volume with no source alone" do
      volume.create(source: nil, size_gib: 1, kek: kek, wrapped_xts: "eHRz", device_id: "cldata", unix_user: "user0")
      expect { volume.drop_source }.not_to change { File.read(volume.main_conf) }
    end
  end

  describe "#key_rotation" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    let(:old_kek) { {"key" => Base64.strict_encode64("o" * 32)} }
    let(:new_kek) { {"key" => Base64.strict_encode64("n" * 32)} }

    def wrap(kek, name, plaintext)
      Base64.strict_encode64(StorageKeyEncryption.aes256gcm_encrypt(Base64.decode64(kek["key"]), name, plaintext))
    end

    before do
      volume.instance_variable_set(:@dir, @dir)
      allow(FileUtils).to receive(:chown)
      volume.write_configs(source: {"type" => "remote", "address" => "[::1]:5500", "psk_identity" => "rs1", "wrapped_psk" => wrap(old_kek, "remote-psk", "psk"), "autofetch" => true},
        wrapped_xts: wrap(old_kek, "xts-key", "x" * 64), device_id: "cldata", unix_user: "user0")
    end

    it "rotates the config-v2 secrets file, without an owner" do
      rotation = volume.key_rotation
      expect(rotation.path).to eq(volume.secrets_conf)
      expect(rotation.file_format).to eq(:config_v2)
      expect(rotation.user).to be_nil
    end

    it "re-wraps every secret with the new key, keeping a backup until it is retired" do
      rotation = volume.key_rotation
      rotation.backup(old_kek)
      expect(File.stat(rotation.backup_path(old_kek)).mode & 0o777).to eq(0o600)

      rotation.rotate(old_kek, new_kek)
      expect(rotation.secrets_v2(volume.secrets_conf, new_kek)).to eq({"xts-key" => "x" * 64, "remote-psk" => "psk"})
      expect { rotation.secrets_v2(volume.secrets_conf, old_kek) }.to raise_error(OpenSSL::Cipher::CipherError)
      expect(File).not_to exist("#{volume.secrets_conf}.new")
      expect(File).to exist(rotation.backup_path(old_kek))

      rotation.retire_backup(old_kek)
      expect(File).not_to exist(rotation.backup_path(old_kek))
    end
  end

  describe "#init_metadata" do
    it "runs ubiblk's initialiser as the volume's user, with the KEK on a pipe" do
      expect(volume).to receive(:run_with_kek_pipe).with(
        ["sudo", "-u", "user0", "/opt/vhost-block-backend/v0.5.1/init-metadata", "-s", "11", "--config", "#{volume.main_conf}.new"],
        kek_pipe: volume.kek_pipe_path, kek_content: kek, owner: "user0",
      )
      volume.init_metadata(kek, "user0")
    end
  end
end
