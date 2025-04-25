# frozen_string_literal: true

require_relative "../lib/cloud_hypervisor"

RSpec.describe CloudHypervisor do
  context "when downloading firmware" do
    subject(:fw) { CloudHypervisor::Firmware.new("202402", "thesha") }

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

  context "when downloading cloud-hypervisor" do
    subject(:ch) { CloudHypervisor::Version.new("35.1", "sha_ch", "sha_remote") }

    let(:gh_ch_remote_url) { "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v35.1/ch-remote-static" }
    let(:gh_ch_bin_url) { "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v35.1/cloud-hypervisor-static" }
    let(:paths) do
      {
        remote: "/opt/cloud-hypervisor/v35.1/ch-remote",
        remote_tmp: "/opt/cloud-hypervisor/v35.1/ch-remote.tmp",
        ch: "/opt/cloud-hypervisor/v35.1/cloud-hypervisor",
        ch_tmp: "/opt/cloud-hypervisor/v35.1/cloud-hypervisor.tmp"
      }
    end

    def setup_existing_files(remote_exist:, ch_exist:)
      expect(File).to receive(:exist?).with(paths[:remote]).and_return(remote_exist)
      expect(File).to receive(:exist?).with(paths[:ch]).and_return(ch_exist)
      expect(FileUtils).to receive(:mkdir_p).with("/opt/cloud-hypervisor/v35.1").twice unless remote_exist && ch_exist
    end

    def setup_file_downloads(sha_remote:, sha_ch:)
      f_remote = instance_double(File, path: paths[:remote_tmp])
      f_ch = instance_double(File, path: paths[:ch_tmp])
      expect(ch).to receive(:safe_write_to_file).with(paths[:remote]).and_yield(f_remote)
      expect(ch).to receive(:safe_write_to_file).with(paths[:ch]).and_yield(f_ch)
      expect(ch).to receive(:curl_file).with(gh_ch_remote_url, paths[:remote_tmp]).and_return(sha_remote)
      expect(ch).to receive(:curl_file).with(gh_ch_bin_url, paths[:ch_tmp]).and_return(sha_ch)
      expect(FileUtils).to receive(:chmod).with("a+x", paths[:remote])
    end

    it "does not download the cloud hypervisor if it exists" do
      setup_existing_files(remote_exist: true, ch_exist: true)
      expect(ch).not_to receive(:curl_file)
      ch.download
    end

    context "when cloud hypervisor does not exist" do
      before do
        setup_existing_files(remote_exist: false, ch_exist: false)
      end

      it "downloads the cloud hypervisor" do
        setup_file_downloads(sha_remote: "sha_remote", sha_ch: "sha_ch")
        expect(FileUtils).to receive(:chmod).with("a+x", paths[:ch])
        ch.download
      end

      it "raises an error if the SHA-256 digest is incorrect" do
        setup_file_downloads(sha_remote: "sha_remote", sha_ch: "sha_ch_incorrect")
        expect(FileUtils).not_to receive(:chmod).with("a+x", paths[:ch])
        expect { ch.download }.to raise_error("Invalid SHA-256 digest")
      end
    end
  end
end
