# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DownloadCloudHypervisor do
  subject(:df) { described_class.new(Strand.new(stack: [{"version" => "35.1", "sha256_ch_bin" => "thesha", "sha256_ch_remote" => "anothersha"}])) }

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
      df = described_class.new(Strand.new(stack: [{"version" => nil, "sha256_ch_bin" => "thesha", "sha256_ch_remote" => "anothersha"}]))
      expect { df.start }.to raise_error RuntimeError, "Version is required"
    end

    it "fails if sha256 for cloud-hypervisor is nil" do
      df = described_class.new(Strand.new(stack: [{"version" => "35.0", "sha256_ch_bin" => nil, "sha256_ch_remote" => "anothersha"}]))
      allow(df).to receive_messages(sshable: sshable, vm_host: vm_host)
      expect { df.start }.to raise_error RuntimeError, "SHA-256 digest of cloud-hypervisor is required"
    end

    it "fails if sha256 for ch-remote is nil" do
      df = described_class.new(Strand.new(stack: [{"version" => "35.0", "sha256_ch_bin" => "thesha", "sha256_ch_remote" => nil}]))
      allow(df).to receive_messages(sshable: sshable, vm_host: vm_host)
      expect { df.start }.to raise_error RuntimeError, "SHA-256 digest of ch-remote is required"
    end
  end

  describe "#download" do
    it "starts to download assets if not started" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_ch_35.1").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer host/bin/download-cloud-hypervisor\\ 35.1\\ thesha\\ anothersha download_ch_35.1")
      expect { df.download }.to nap(15)
    end

    it "uses known sha256s" do
      df = described_class.new(Strand.new(stack: [{"version" => "35.1", "sha256_ch_bin" => nil, "sha256_ch_remote" => nil}]))
      allow(df).to receive_messages(sshable: sshable, vm_host: vm_host)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_ch_35.1").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer host/bin/download-cloud-hypervisor\\ 35.1\\ e8426b0733248ed559bea64eb04d732ce8a471edc94807b5e2ecfdfc57136ab4\\ 337bd88183f6886f1c7b533499826587360f23168eac5aabf38e6d6b977c93b0 download_ch_35.1")
      expect { df.download }.to nap(15)
    end

    it "waits for manual intervention if failed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_ch_35.1").and_return("Failed")
      expect { df.download }.to raise_error RuntimeError, "Failed to download cloud hypervisor version 35.1 on VmHost[\"#{vm_host.ubid}\"]"
    end

    it "waits for the download to complete" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_ch_35.1").and_return("InProgess")
      expect { df.download }.to nap(15)
    end

    it "exits if succeeded" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check download_ch_35.1").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean download_ch_35.1")
      expect { df.download }.to exit({"msg" => "cloud hypervisor downloaded", "version" => "35.1", "sha256_ch_bin" => "thesha", "sha256_ch_remote" => "anothersha"})
    end
  end
end
