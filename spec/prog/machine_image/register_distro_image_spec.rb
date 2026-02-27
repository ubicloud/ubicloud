# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::RegisterDistroImage do
  subject(:nx) {
    described_class.new(Strand.new(prog: "MachineImage::RegisterDistroImage", label: "start", stack: [{"subject_id" => version.id, "vm_host_id" => vm_host.id, "url" => url, "sha256" => sha256}])).tap {
      it.instance_variable_set(:@machine_image_version, version)
      it.instance_variable_set(:@vm_host, vm_host)
    }
  }

  let(:project) { Project.create(name: "test-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }
  let(:vm_host) { create_vm_host }
  let(:sshable) { vm_host.sshable }

  let(:mi) {
    MachineImage.create(
      name: "ubuntu-24.04",
      description: "Ubuntu 24.04 LTS",
      project_id: project.id,
      location_id: location.id
    )
  }

  let(:url) { "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img" }
  let(:sha256) { "abc123def456" }

  let(:version) {
    MachineImageVersion.create(
      machine_image_id: mi.id,
      version: 1,
      state: "creating",
      size_gib: 0,
      s3_bucket: "test-bucket",
      s3_prefix: "#{mi.ubid}/1/",
      s3_endpoint: "https://r2.example.com"
    )
  }

  let(:daemon_name) { "register_distro_#{version.ubid}" }

  describe ".assemble" do
    before do
      allow(Config).to receive(:machine_image_archive_bucket).and_return("test-bucket")
      allow(Config).to receive(:machine_image_archive_endpoint).and_return("https://r2.example.com")
    end

    it "creates a MachineImageVersion and strand for the machine image" do
      st = described_class.assemble(mi, vm_host_id: vm_host.id, url: url, sha256: sha256)
      expect(st).to be_a(Strand)
      expect(st.prog).to eq("MachineImage::RegisterDistroImage")
      expect(st.label).to eq("start")

      created_version = MachineImageVersion[st.id]
      expect(created_version.machine_image_id).to eq(mi.id)
      expect(created_version.version).to eq(1)
      expect(created_version.state).to eq("creating")
      expect(created_version.size_gib).to eq(0)
      expect(created_version.s3_bucket).to eq("test-bucket")
      expect(created_version.s3_prefix).to eq("#{mi.ubid}/1/")
      expect(created_version.s3_endpoint).to eq("https://r2.example.com")
    end

    it "auto-increments version number" do
      MachineImageVersion.create(
        machine_image_id: mi.id,
        version: 3,
        state: "available",
        size_gib: 10,
        s3_bucket: "test-bucket",
        s3_prefix: "#{mi.ubid}/3/",
        s3_endpoint: "https://r2.example.com"
      )

      st = described_class.assemble(mi, vm_host_id: vm_host.id, url: url, sha256: sha256)
      created_version = MachineImageVersion[st.id]
      expect(created_version.version).to eq(4)
      expect(created_version.s3_prefix).to eq("#{mi.ubid}/4/")
    end
  end

  describe "#start" do
    it "registers deadline and hops to create_kek" do
      expect(nx).to receive(:register_deadline).with(nil, 86400)
      expect { nx.start }.to hop("create_kek")
    end

    it "fails if no host available" do
      bad_nx = described_class.new(Strand.new(prog: "MachineImage::RegisterDistroImage", label: "start", stack: [{"subject_id" => version.id, "vm_host_id" => nil, "url" => url, "sha256" => sha256}]))
      expect { bad_nx.start }.to raise_error(RuntimeError, "No host available for distro image registration")
    end
  end

  describe "#create_kek" do
    it "creates a StorageKeyEncryptionKey and hops to register" do
      expect { nx.create_kek }.to hop("register")
      version.reload
      expect(version.key_encryption_key_1).not_to be_nil
      expect(version.key_encryption_key_1.algorithm).to eq("aes-256-gcm")
      expect(version.key_encryption_key_1.auth_data).to eq(version.ubid)
    end
  end

  describe "#register" do
    before do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: Base64.encode64("test-key-32-bytes-long-enough!!!"),
        init_vector: Base64.encode64("test-iv-16bytes!"),
        auth_data: version.ubid
      )
      version.update(key_encryption_key_1_id: kek.id)
    end

    it "sets version available on Succeeded" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat var/log/#{daemon_name}.stdout").and_return("20\n")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")
      expect { nx.register }.to hop("wait")
      version.reload
      expect(version.state).to eq("available")
      expect(version.size_gib).to eq(20)
      expect(version.activated_at).not_to be_nil
    end

    it "sets minimum size_gib to 1" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat var/log/#{daemon_name}.stdout").and_return("0\n")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")
      expect { nx.register }.to hop("wait")
      expect(version.reload.size_gib).to eq(1)
    end

    it "starts the daemon on NotStarted" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("NotStarted")
      expect(CloudflareR2).to receive(:generate_temp_credentials).and_return({access_key_id: "ak", secret_access_key: "sk", session_token: "st"})
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo host/bin/register-distro-image' #{daemon_name}", stdin: anything)
      expect { nx.register }.to nap(15)
    end

    it "handles failure by setting state to failed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("cat var/log/#{daemon_name}.stderr").and_return("some error")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")
      expect { nx.register }.to hop("wait")
      expect(version.reload.state).to eq("failed")
    end

    it "handles failure when stderr read fails" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("cat var/log/#{daemon_name}.stderr").and_raise(RuntimeError)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean #{daemon_name}")
      expect { nx.register }.to hop("wait")
      expect(version.reload.state).to eq("failed")
    end

    it "naps when status is in progress" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check #{daemon_name}").and_return("InProgress")
      expect { nx.register }.to nap(15)
    end
  end

  describe "#wait" do
    it "hops to destroy when destroy semaphore is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.wait }.to hop("destroy")
    end

    it "auto-destroys failed versions older than 1 hour" do
      version.update(state: "failed", created_at: Time.now - 7200)
      expect(nx).to receive(:when_destroy_set?)
      expect { nx.wait }.to hop("destroy")
    end

    it "naps for 30 seconds when nothing to do" do
      expect(nx).to receive(:when_destroy_set?)
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "finalizes billing, sets state to destroying, and hops to destroy_record" do
      expect(nx).to receive(:decr_destroy)
      expect { nx.destroy }.to hop("destroy_record")
      expect(version.reload.state).to eq("destroying")
    end
  end

  describe "#destroy_record" do
    before do
      kek = StorageKeyEncryptionKey.create(
        algorithm: "aes-256-gcm",
        key: Base64.encode64("test-key-32-bytes-long-enough!!!"),
        init_vector: Base64.encode64("test-iv-16bytes!"),
        auth_data: version.ubid
      )
      version.update(key_encryption_key_1_id: kek.id)
    end

    it "deletes S3 objects, destroys KEK and version" do
      expect(nx).to receive(:delete_s3_objects)
      kek_id = version.key_encryption_key_1_id
      expect { nx.destroy_record }.to exit({"msg" => "distro image version destroyed"})
      expect(MachineImageVersion[version.id]).to be_nil
      expect(StorageKeyEncryptionKey[kek_id]).to be_nil
    end

    it "handles version without KEK" do
      version.update(key_encryption_key_1_id: nil)
      expect(nx).to receive(:delete_s3_objects)
      expect { nx.destroy_record }.to exit({"msg" => "distro image version destroyed"})
      expect(MachineImageVersion[version.id]).to be_nil
    end
  end
end
