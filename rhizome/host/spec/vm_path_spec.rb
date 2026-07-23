# frozen_string_literal: true

require_relative "../lib/vm_path"

RSpec.describe VmPath do
  subject(:vp) { described_class.new("test'vm") }

  it ".define_new_method raises if the method is already defined" do
    expect { described_class.define_new_method(:inspect) {} }.to raise_error(RuntimeError, "BUG")
  end

  it "can compute a path" do
    expect(vp.guest_ephemeral).to eq("/vm/test'vm/guest_ephemeral")
  end

  it "snakifies difficult characters" do
    expect(vp.serial_log).to eq("/vm/test'vm/serial.log")
  end

  it "can read file contents" do
    expect(File).to receive(:read).with(vp.serial_log).and_return("\n")
    expect(vp.read_serial_log).to eq("")
  end

  context "when writing" do
    it "affixes a newline if it is missing" do
      expect(File).to receive(:write).with(vp.serial_log, "test content\n")
      vp.write_serial_log("test content")
    end

    it "doesn't add more newlines than necessary" do
      expect(File).to receive(:write).with(vp.serial_log, "test content\n")
      vp.write_serial_log("test content\n")
    end
  end

  describe "#systemd_service" do
    it "returns escaped systemd service path" do
      expect(IO).to receive(:popen).with(["systemd-escape", "test'vm.service"]).and_yield(StringIO.new("test\\x27vm.service\n"))
      expect(vp.systemd_service).to eq("/etc/systemd/system/test\\x27vm.service")
    end
  end

  describe "#write_systemd_service" do
    it "writes to the escaped systemd service path" do
      expect(IO).to receive(:popen).with(["systemd-escape", "test'vm.service"]).and_yield(StringIO.new("test\\x27vm.service\n"))
      expect(File).to receive(:write).with("/etc/systemd/system/test\\x27vm.service", "unit content\n")
      vp.write_systemd_service("unit content")
    end
  end

  describe "#dnsmasq_service" do
    it "returns dnsmasq service path" do
      expect(vp.dnsmasq_service).to eq("/etc/systemd/system/test'vm-dnsmasq.service")
    end
  end

  describe "#write_dnsmasq_service" do
    it "writes to the dnsmasq service path" do
      expect(File).to receive(:write).with("/etc/systemd/system/test'vm-dnsmasq.service", "dnsmasq content\n")
      vp.write_dnsmasq_service("dnsmasq content")
    end
  end

  describe "#write_yaml_*" do
    it "serializes data to YAML and writes it" do
      expect(File).to receive(:write).with(vp.meta_data, satisfy { |s| s.include?("key: value") })
      vp.write_yaml_meta_data({"key" => "value"})
    end

    it "replaces the leading --- with the given prefix" do
      expect(File).to receive(:write).with(vp.user_data, satisfy { |s| s.start_with?("#cloud-config\n") })
      vp.write_yaml_user_data({"key" => "value"}, prefix: "#cloud-config")
    end
  end
end
