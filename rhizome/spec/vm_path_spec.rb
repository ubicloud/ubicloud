# frozen_string_literal: true

require_relative "../lib/vm_path"

RSpec.describe VmPath do
  subject(:vp) { described_class.new("test'vm") }

  it "can compute a path" do
    expect(vp.guest_mac).to eq("/vm/test'vm/guest_mac")
  end

  it "can escape a path" do
    expect(vp.q_guest_mac).to eq("/vm/test\\'vm/guest_mac")
  end

  it "will snakeify difficult characters" do
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
end
