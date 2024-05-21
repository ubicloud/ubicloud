# frozen_string_literal: true

require_relative "../lib/cloud_hypervisor"

RSpec.describe CloudHypervisor do
  subject(:fw) { CloudHypervisor::FirmwareClass.new("202402", "thesha") }

  describe "#download" do
    it "can use an existing firmware" do
      expect(File).to receive(:exist?).with("/opt/fw/CLOUDHV-202402.fd").and_return(true)
      expect(fw).not_to receive(:curl_firmware)
      fw.download
    end

    it "can download a firmware" do
      expect(File).to receive(:exist?).with("/opt/fw/CLOUDHV-202402.fd").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/opt/fw")
      f = instance_double(File)
      expect(fw).to receive(:safe_write_to_file).with("/opt/fw/CLOUDHV-202402.fd").and_yield(f)
      expect(fw).to receive(:curl_firmware).with(f).and_return("thesha")
      fw.download
    end

    it "fails if sha is incorrect" do
      expect(File).to receive(:exist?).with("/opt/fw/CLOUDHV-202402.fd").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/opt/fw")
      f = instance_double(File)
      expect(fw).to receive(:safe_write_to_file).with("/opt/fw/CLOUDHV-202402.fd").and_yield(f)
      expect(fw).to receive(:curl_firmware).with(f).and_return("anothersha")
      expect { fw.download }.to raise_error("Invalid SHA-256 digest")
    end
  end
end
