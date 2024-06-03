# frozen_string_literal: true

require_relative "../lib/cloud_hypervisor"

RSpec.describe CloudHypervisor do
  context "when downloading firmware" do
    subject(:fw) { CloudHypervisor::FirmwareClass.new("202402", "thesha") }

    let(:gh_fw_url) { "https://github.com/ubicloud/build-edk2-firmware/releases/download/edk2-stable202402-x64/CLOUDHV-x64.fd" }
    let(:firmware_path) { "/opt/fw/CLOUDHV-202402.fd" }
    let(:firmware_tmp_path) { "/opt/fw/CLOUDHV-202402.fd.tmp" }

    it "does not download the firmware if it exists" do
      expect(File).to receive(:exist?).with(firmware_path).and_return(true)
      expect(fw).not_to receive(:curl_file)
      fw.download
    end

    context "when firmware does not exist" do
      before do
        expect(File).to receive(:exist?).with(firmware_path).and_return(false)
        expect(FileUtils).to receive(:mkdir_p).with("/opt/fw")
      end

      it "downloads the firmware" do
        f = instance_double(File, path: firmware_tmp_path)
        expect(Arch).to receive(:sym).and_return(:x64).at_least(:once)
        expect(fw).to receive(:safe_write_to_file).with(firmware_path).and_yield(f)
        expect(fw).to receive(:curl_file).with(gh_fw_url, firmware_tmp_path).and_return("thesha")
        fw.download
      end

      it "raises an error if the SHA-256 digest is incorrect" do
        f = instance_double(File, path: firmware_tmp_path)
        expect(Arch).to receive(:sym).and_return(:x64).at_least(:once)
        expect(fw).to receive(:safe_write_to_file).with(firmware_path).and_yield(f)
        expect(fw).to receive(:curl_file).with(gh_fw_url, firmware_tmp_path).and_return("anothersha")
        expect { fw.download }.to raise_error("Invalid SHA-256 digest")
      end
    end
  end
end
