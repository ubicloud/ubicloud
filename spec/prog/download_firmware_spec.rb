# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DownloadFirmware do
  subject(:df) { described_class.new(Strand.new(stack: [{"version" => "202405", "sha256" => "thesha"}])) }

  let(:sshable) { vm_host.sshable }
  let(:vm_host) { create_vm_host }

  before do
    allow(df).to receive_messages(sshable: sshable, vm_host: vm_host)
  end

  describe "#start" do
    it "hops to download" do
      expect { df.start }.to hop("download")
    end

    it "fails if version is nil" do
      df = described_class.new(Strand.new(stack: [{"version" => nil, "sha256" => "thesha"}]))
      expect { df.start }.to raise_error RuntimeError, "Version is required"
    end

    it "fails if sha256 is nil" do
      df = described_class.new(Strand.new(stack: [{"version" => "202405", "sha256" => nil}]))
      expect { df.start }.to raise_error RuntimeError, "SHA-256 digest is required"
    end
  end

  describe "#download" do
    it "starts to download firmware if not started" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_firmware_202405").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'host/bin/download-firmware 202405 thesha' download_firmware_202405")
      expect { df.download }.to nap(15)
    end

    it "waits for manual intervention if failed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_firmware_202405").and_return("Failed")
      expect { df.download }.to raise_error RuntimeError, "Failed to download firmware version 202405 on VmHost[\"#{vm_host.ubid}\"]"
    end

    it "waits for the download to complete" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_firmware_202405").and_return("InProgess")
      expect { df.download }.to nap(15)
    end

    it "exits if succeeded" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_firmware_202405").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean download_firmware_202405")
      expect { df.download }.to exit({"msg" => "firmware downloaded", "version" => "202405", "sha256" => "thesha"})
    end
  end
end
