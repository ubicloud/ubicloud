# frozen_string_literal: true

require_relative "../lib/ember_vm"
require_relative "../lib/slot"
require "tmpdir"

RSpec.describe EmberVm do
  subject(:vm) { described_class.new(slot, ch_version: "53.0") }

  let(:slot) { Slot.new(0, ip6_block: "2a01:4f8:120:9208:2::/79") }

  it "derives its paths and its binary from the slot and the version" do
    expect(vm.api_sock).to eq("/vm/emslot0000/ch-api.sock")
    expect(vm.serial_log).to eq("/vm/emslot0000/serial.log")
    expect(vm.restore_dir).to eq("/vm/emslot0000/restore")
    expect(vm.unit).to eq("emslot0000.service")
    expect(vm.ch_bin).to eq("/opt/cloud-hypervisor/v53.0/cloud-hypervisor")
  end

  describe "#prepare_restore" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        @template = File.join(dir, "template")
        FileUtils.mkdir_p(@template)
        File.write(File.join(@template, "config.json"),
          JSON.generate({"serial" => {"file" => "/old/serial"}}))
        File.write(File.join(@template, "memory-ranges"), "memory")
        example.run
      end
    end

    before do
      allow(vm).to receive_messages(restore_dir: File.join(@root, "restore"), serial_log: "/new/serial")
      allow(FileUtils).to receive(:chown)
      allow(slot).to receive(:dir).and_return(@root)
    end

    it "points the per-VM paths at this slot" do
      vm.prepare_restore(@template)
      config = JSON.parse(File.read(File.join(@root, "restore", "config.json")))
      expect(config["serial"]["file"]).to eq("/new/serial")
    end

    it "hard-links the big file rather than copying hundreds of megabytes" do
      vm.prepare_restore(@template)
      linked = File.join(@root, "restore", "memory-ranges")
      expect(File.stat(linked).ino).to eq(File.stat(File.join(@template, "memory-ranges")).ino)
    end

    it "copies when it cannot link, across a filesystem boundary" do
      expect(File).to receive(:link).and_raise(Errno::EXDEV)
      vm.prepare_restore(@template)
      expect(File.read(File.join(@root, "restore", "memory-ranges"))).to eq("memory")
    end

    it "chowns only what this slot owns, never the linked template" do
      expect(FileUtils).to receive(:chown).with("emslot0000", "emslot0000", [
        @root, File.join(@root, "restore"), File.join(@root, "restore", "config.json"),
      ])
      vm.prepare_restore(@template)
    end

    it "leaves a config with no serial alone" do
      File.write(File.join(@template, "config.json"), JSON.generate({"cpus" => {"boot_vcpus" => 1}}))
      vm.prepare_restore(@template)
      config = JSON.parse(File.read(File.join(@root, "restore", "config.json")))
      expect(config).to eq({"cpus" => {"boot_vcpus" => 1}})
    end
  end

  describe "#write_unit" do
    it "gives the VMM the one capability it needs, and no more" do
      written = nil
      expect(vm).to receive(:safe_write_to_file).with("/etc/systemd/system/emslot0000.service", anything) { |_path, content| written = content }
      vm.write_unit("An ember", "--restore x")
      expect(written).to include("AmbientCapabilities=CAP_NET_ADMIN")
      expect(written).to include("CapabilityBoundingSet=CAP_NET_ADMIN")
      expect(written).to include("User=emslot0000")
      expect(written).to include("NetworkNamespacePath=/var/run/netns/emslot0000")
      expect(written).to include("ExecStart=/opt/cloud-hypervisor/v53.0/cloud-hypervisor -v --restore x")
      expect(written).not_to include("CPUQuota")
    end

    it "holds an ember to its CPU limit" do
      written = nil
      expect(vm).to receive(:safe_write_to_file) { |_path, content| written = content }
      vm.write_unit("An ember", "--restore x", cpu_quota: "CPUQuota=50%")
      expect(written).to include("Slice=ember.slice\nCPUQuota=50%\n")
    end
  end

  describe "#start" do
    it "writes the unit and waits for the VM to be running" do
      expect(vm).to receive(:clean_paths)
      expect(vm).to receive(:write_unit).with("Ember emslot0000",
        "--api-socket path=#{vm.api_sock} --restore source_url=file://#{vm.restore_dir},memory_restore_mode=ondemand,resume=true",
        cpu_quota: "CPUQuota=50%")
      expect(vm).to receive(:r).with("systemctl", "daemon-reload")
      expect(vm).to receive(:r).with("systemctl", "start", "emslot0000.service")
      expect(vm).to receive(:wait_api)
      expect(vm).to receive(:wait_state).with("Running")
      vm.start(cpu_percent_limit: 50)
    end
  end

  describe "#boot" do
    it "cold boots from the root image with no data disk" do
      allow(vm).to receive_messages(clean_paths: nil, r: nil, wait_api: nil, wait_state: nil)
      allow(FileUtils).to receive(:rm_f)
      written = nil
      expect(vm).to receive(:safe_write_to_file) { |_path, content| written = content }
      vm.boot(root_image: "/images/root.raw", memory_mib: 384, vcpus: 1)
      expect(written).to include("/images/root.raw")
      expect(written).to include("size=384M")
      # Nothing in the guest listens for the host.
      expect(written).not_to include("--vsock")
    end
  end

  describe "the cloud-hypervisor API" do
    it "sends no body for an action that takes none" do
      # cloud-hypervisor answers 400 when an action that takes no body is
      # given one, which is how vm.pause was broken.
      request = capture_request { vm.pause_vm }
      expect(request).to start_with("PUT /api/v1/vm.pause HTTP/1.1")
      expect(request).not_to include("Content-Length")
      expect(request).to end_with("\r\n\r\n")
    end

    it "sends a body for an action that takes one" do
      request = capture_request { vm.add_disk("/vol/vhost.sock") }
      expect(request).to include("Content-Type: application/json")
      body = request.split("\r\n\r\n", 2).last
      expect(JSON.parse(body)).to include("vhost_socket" => "/vol/vhost.sock", "id" => "data")
    end

    it "raises when cloud-hypervisor refuses" do
      expect { capture_request(status: "400 Bad Request", body: '["Bad Request"]') { vm.pause_vm } }
        .to raise_error(RuntimeError, /returned 400/)
    end

    it "reads the VM's state, and says nothing when it cannot" do
      expect(vm).to receive(:api_get).and_return([200, '{"state":"Running"}'])
      expect(vm.state).to eq("Running")
      expect(vm).to receive(:api_get).and_return([500, ""])
      expect(vm.state).to be_nil
      expect(vm).to receive(:api_get).and_return([200, "not json"])
      expect(vm.state).to be_nil
    end

    it "reads the VM's state over the socket" do
      request = capture_request(status: "200 OK", body: '{"state":"Running"}') {
        expect(vm.state).to eq("Running")
      }
      expect(request).to start_with("GET /api/v1/vm.info HTTP/1.1")
    end

    it "treats an unreachable socket as no answer" do
      expect(UNIXSocket).to receive(:new).and_raise(Errno::ENOENT)
      expect(vm.send(:api_get, "/api/v1/vmm.ping")).to eq([nil, nil])
    end
  end

  describe "#snapshot" do
    it "leaves the template readable by every other slot" do
      # The snapshot is written by the slot user at 0600, and every slot has
      # to be able to restore from it.
      allow(FileUtils).to receive_messages(mkdir_p: nil, chown: nil, chown_R: nil)
      allow(vm).to receive(:api_put)
      allow(Dir).to receive(:children).and_return(["memory-ranges"])
      expect(FileUtils).to receive(:chown_R).with("root", "root", "/templates/ct1")
      expect(File).to receive(:chmod).with(0o755, "/templates/ct1")
      expect(File).to receive(:chmod).with(0o644, "/templates/ct1/memory-ranges")
      vm.snapshot("/templates/ct1")
    end
  end

  describe "#power_button" do
    it "presses the guest's ACPI power button" do
      expect(vm).to receive(:api_put).with("/api/v1/vm.power-button")
      vm.power_button
    end
  end

  describe "#wait_exit" do
    before { allow(vm).to receive(:sleep) }

    it "is true once cloud-hypervisor stops answering" do
      answers = [[200, ""], [nil, nil]]
      allow(vm).to receive(:api_get).with("/api/v1/vmm.ping") { answers.shift }
      expect(vm.wait_exit(timeout: 10)).to be true
      expect(answers).to be_empty
    end

    it "is false when it is still there at the deadline" do
      allow(vm).to receive(:api_get).and_return([200, ""])
      expect(vm.wait_exit(timeout: 0)).to be false
    end
  end

  describe "#wait_serial" do
    around do |example|
      Dir.mktmpdir do |dir|
        @serial = File.join(dir, "serial.log")
        example.run
      end
    end

    before do
      allow(vm).to receive(:serial_log).and_return(@serial)
      allow(vm).to receive(:sleep)
    end

    it "returns once the guest has printed the marker" do
      File.write(@serial, "boot noise\nCELL-TEMPLATE-READY\n")
      expect(vm.wait_serial("CELL-TEMPLATE-READY", timeout: 10)).to be true
    end

    it "keeps reading until the marker appears" do
      expect(vm).to receive(:sleep).with(0.1) { File.write(@serial, "CELL-TEMPLATE-READY") }
      expect(vm.wait_serial("CELL-TEMPLATE-READY", timeout: 10)).to be true
    end

    it "gives up on a guest that never prints it" do
      File.write(@serial, "boot noise")
      expect { vm.wait_serial("CELL-TEMPLATE-READY", timeout: 0) }.to raise_error(/never printed CELL-TEMPLATE-READY/)
    end
  end

  describe "#shutdown" do
    before do
      allow(FileUtils).to receive(:rm_f)
      allow(vm).to receive(:r)
    end

    it "asks the VMM to exit, waits for it, and removes the unit" do
      expect(vm).to receive(:api_put).with("/api/v1/vmm.shutdown")
      expect(vm).to receive(:running?).and_return(false)
      expect(vm).to receive(:r).with("systemctl", "stop", "emslot0000.service")
      expect(FileUtils).to receive(:rm_f).with("/etc/systemd/system/emslot0000.service")
      vm.shutdown
    end

    it "stops the unit anyway when the API will not answer" do
      expect(vm).to receive(:api_put).and_raise("no socket")
      expect(vm).to receive(:running?).and_return(false)
      expect(vm).to receive(:r).with("systemctl", "stop", "emslot0000.service")
      vm.shutdown
    end

    it "waits while the VMM is still running" do
      expect(vm).to receive(:api_put)
      still_running = [true, false]
      allow(vm).to receive(:running?) { still_running.shift }
      allow(vm).to receive(:sleep)
      expect(vm).to receive(:r).with("systemctl", "stop", "emslot0000.service")
      vm.shutdown
      expect(still_running).to be_empty
    end

    it "gives up waiting rather than hanging on a VMM that will not go" do
      expect(vm).to receive(:api_put)
      allow(vm).to receive(:running?).and_return(true)
      expect(vm).to receive(:monotonic).and_return(0, 100)
      expect(vm).to receive(:r).with("systemctl", "stop", "emslot0000.service")
      vm.shutdown
    end

    it "does not mind systemctl failing" do
      allow(vm).to receive_messages(api_put: nil, running?: false)
      expect(vm).to receive(:r).and_raise(CommandFail.new("no unit", "", ""))
      expect { vm.shutdown }.not_to raise_error
    end
  end

  describe "#running?" do
    it "asks systemd" do
      expect(vm).to receive(:r).with("systemctl", "is-active", "--quiet", "emslot0000.service")
      expect(vm).to be_running
    end

    it "is false when the unit is not active" do
      expect(vm).to receive(:r).and_raise(CommandFail.new("inactive", "", ""))
      expect(vm).not_to be_running
    end
  end

  describe "waiting" do
    it "returns once the API answers" do
      expect(vm).to receive(:api_get).and_return([200, ""])
      expect(vm.wait_api).to be true
    end

    it "gives up on an API that never answers" do
      allow(vm).to receive(:api_get).and_return([nil, nil])
      expect { vm.wait_api(timeout: 0) }.to raise_error(RuntimeError, /never answered/)
    end

    it "keeps polling until the API comes up" do
      replies = [[nil, nil], [200, ""]]
      allow(vm).to receive(:api_get) { replies.shift }
      expect(vm.wait_api).to be true
      expect(replies).to be_empty
    end

    it "keeps polling until the VM reaches the state" do
      states = %w[Created Running]
      allow(vm).to receive(:state) { states.shift }
      expect(vm.wait_state("Running")).to be true
      expect(states).to be_empty
    end

    it "returns once the VM reaches the state" do
      expect(vm).to receive(:state).and_return("Running")
      expect(vm.wait_state("Running")).to be true
    end

    it "gives up on a state that never arrives" do
      allow(vm).to receive(:state).and_return("Created")
      expect(vm).to receive(:monotonic).and_return(0, 100)
      expect { vm.wait_state("Running") }
        .to raise_error(RuntimeError, /never reached Running/)
    end
  end

  describe "reading a response" do
    let(:socket) { instance_double(UNIXSocket, close: nil) }

    it "gives up when the socket goes quiet" do
      expect(IO).to receive(:select).and_return(nil)
      expect(vm.send(:read_http, socket)).to eq([0, ""])
    end

    it "stops when the peer hangs up mid-response" do
      allow(IO).to receive(:select).and_return([socket])
      expect(socket).to receive(:read_nonblock).and_return(nil)
      expect(vm.send(:read_http, socket)).to eq([0, ""])
    end

    it "goes round again when the socket says it has nothing yet" do
      allow(IO).to receive(:select).and_return([socket])
      chunks = [:wait_readable, "HTTP/1.1 204 No Content\r\n\r\n"]
      allow(socket).to receive(:read_nonblock) { chunks.shift }
      expect(vm.send(:read_http, socket)).to eq([204, ""])
      expect(chunks).to be_empty
    end

    it "keeps reading until the whole body has arrived" do
      allow(IO).to receive(:select).and_return([socket])
      chunks = ["HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab", "cd"]
      allow(socket).to receive(:read_nonblock) { chunks.shift }
      expect(vm.send(:read_http, socket)).to eq([200, "abcd"])
      expect(chunks).to be_empty
    end
  end

  describe "#clean_paths" do
    it "clears the sockets a previous run left behind" do
      expect(FileUtils).to receive(:rm_f).with("/vm/emslot0000/ch-api.sock")
      expect(FileUtils).to receive(:rm_f).with("/vm/emslot0000/ch-api.sock.lock")
      expect(FileUtils).to receive(:mkdir_p).with("/vm/emslot0000")
      vm.clean_paths
    end
  end

  # Serve one canned HTTP response over a unix socket and return the request
  # the VM sent, so the framing itself is checked rather than mocked.
  def capture_request(status: "204 No Content", body: "")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "api.sock")
      server = UNIXServer.new(path)
      allow(vm).to receive(:api_sock).and_return(path)
      request = nil
      thread = Thread.new do
        conn = server.accept
        request = conn.readpartial(65_536)
        response = "HTTP/1.1 #{status}\r\n"
        response << "Content-Length: #{body.bytesize}\r\n\r\n#{body}" unless body.empty?
        response << "\r\n" if body.empty?
        conn.write(response)
        conn.close
      end
      begin
        yield
      ensure
        thread.join(5)
        server.close
      end
      request
    end
  end
end
