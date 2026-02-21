# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::RegisterDistroImage do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-project") }
  let(:vm_host) { create_vm_host }
  let(:machine_image) {
    MachineImage.create(
      name: "ubuntu-noble",
      description: "ubuntu-noble 20250502.1",
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      state: "creating",
      s3_bucket: "test-bucket",
      s3_prefix: "public/ubuntu-noble/20250502.1/mi123/",
      s3_endpoint: "https://r2.example.com",
      encrypted: false,
      size_gib: 0,
      visible: true,
      version: "20250502.1"
    )
  }
  let(:strand) {
    Strand.create_with_id(
      machine_image,
      prog: "MachineImage::RegisterDistroImage",
      label: "start",
      stack: [{
        "subject_id" => machine_image.id,
        "vm_host_id" => vm_host.id,
        "url" => "https://cloud-images.ubuntu.com/noble/release/ubuntu-24.04-server-cloudimg-amd64.img",
        "sha256" => "abc123def456"
      }]
    )
  }
  let(:sshable) { nx.vm_host.sshable }

  before do
    allow(Config).to receive_messages(
      machine_image_archive_access_key: "test-key-id",
      machine_image_archive_secret_key: "test-secret-key"
    )
  end

  describe "#start" do
    it "hops to register when host is available" do
      expect { nx.start }.to hop("register")
    end

    it "fails when host is not found" do
      strand.stack.first["vm_host_id"] = "00000000-0000-0000-0000-000000000000"
      strand.modified!(:stack)
      strand.save_changes
      nx.instance_variable_set(:@frame, nil)
      nx.instance_variable_set(:@vm_host, nil)

      expect { nx.start }.to raise_error(RuntimeError, "No host available for distro image registration")
    end
  end

  describe "#register" do
    it "starts the daemonizer when not started" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check register_distro_/).and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer 'sudo host\/bin\/register-distro-image' register_distro_/, stdin: anything) do |_, stdin:|
        params = JSON.parse(stdin)
        expect(params["url"]).to include("ubuntu")
        expect(params["sha256"]).to eq("abc123def456")
        expect(params["archive_bin"]).to eq("/opt/vhost-block-backend/v0.4.0/archive")
        expect(params["init_metadata_bin"]).to eq("/opt/vhost-block-backend/v0.4.0/init-metadata")
        expect(params["s3_key_id"]).to eq("test-key-id")
        expect(params["s3_secret_key"]).to eq("test-secret-key")
        expect(params["target_config_content"]).to include("[target]")
        expect(params["target_config_content"]).to include('bucket = "test-bucket"')
      end
      expect { nx.register }.to nap(15)
    end

    it "marks available and hops to wait when succeeded" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check register_distro_/).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with(/cat var\/log\/register_distro_.*\.stdout/).and_return("20\n")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean register_distro_/)
      expect { nx.register }.to hop("wait")
      machine_image.reload
      expect(machine_image.state).to eq("available")
      expect(machine_image.size_gib).to eq(20)
    end

    it "uses minimum size of 1 GiB" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check register_distro_/).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with(/cat var\/log\/register_distro_.*\.stdout/).and_return("0\n")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean register_distro_/)
      expect { nx.register }.to hop("wait")
      expect(machine_image.reload.size_gib).to eq(1)
    end

    it "marks failed and hops to wait when registration fails" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check register_distro_/).and_return("Failed")
      expect(sshable).to receive(:_cmd).with(/cat var\/log\/register_distro_.*\.stderr/).and_return("download error\n")
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean register_distro_/)
      expect(Clog).to receive(:emit).with("Failed to register distro image", hash_including(distro_image_register_failed: hash_including(stderr: "download error")))
      expect { nx.register }.to hop("wait")
      expect(machine_image.reload.state).to eq("failed")
    end

    it "handles stderr read failure" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check register_distro_/).and_return("Failed")
      expect(sshable).to receive(:_cmd).with(/cat var\/log\/register_distro_.*\.stderr/).and_raise(RuntimeError)
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --clean register_distro_/)
      expect(Clog).to receive(:emit).with("Failed to register distro image", hash_including(distro_image_register_failed: hash_including(stderr: nil)))
      expect { nx.register }.to hop("wait")
      expect(machine_image.reload.state).to eq("failed")
    end

    it "naps when in progress" do
      expect(sshable).to receive(:_cmd).with(/common\/bin\/daemonizer --check register_distro_/).and_return("InProgress")
      expect { nx.register }.to nap(15)
    end
  end

  describe "#wait" do
    it "hops to destroy when destroy semaphore is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.wait }.to hop("destroy")
    end

    it "naps when no semaphore is set" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "deletes S3 objects and destroys the record" do
      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      response = instance_double(Aws::S3::Types::ListObjectsV2Output, contents: [], is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)

      mi_id = machine_image.id
      expect { nx.destroy }.to exit({"msg" => "distro image destroyed"})
      expect(MachineImage[mi_id]).to be_nil
    end

    it "finalizes billing records before destroying" do
      project.update(billable: true)
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: machine_image.id,
        resource_name: machine_image.name,
        billing_rate_id: BillingRate.from_resource_properties("MachineImageStorage", "standard", "hetzner-fsn1")["id"],
        amount: 20
      )

      s3_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(s3_client)
      response = instance_double(Aws::S3::Types::ListObjectsV2Output, contents: [], is_truncated: false)
      expect(s3_client).to receive(:list_objects_v2).and_return(response)

      expect { nx.destroy }.to exit({"msg" => "distro image destroyed"})
      expect(BillingRecord[br.id].span.unbounded_end?).to be false
    end
  end

  describe "#target_config_toml" do
    it "generates correct TOML for unencrypted distro image" do
      toml = nx.send(:target_config_toml)
      expect(toml).to include("[target]")
      expect(toml).to include('storage = "s3"')
      expect(toml).to include('bucket = "test-bucket"')
      expect(toml).to include("connections = 16")
      expect(toml).to include("[secrets.s3-key-id]")
      expect(toml).to include("[secrets.s3-secret-key]")
      expect(toml).not_to include("archive_kek")
    end
  end

  describe "#register_params" do
    it "generates correct params" do
      params = nx.send(:register_params)
      expect(params["url"]).to include("ubuntu")
      expect(params["sha256"]).to eq("abc123def456")
      expect(params["work_dir"]).to include("register-distro-")
      expect(params["archive_bin"]).to include("archive")
      expect(params["init_metadata_bin"]).to include("init-metadata")
      expect(params["s3_key_id"]).to eq("test-key-id")
      expect(params["s3_secret_key"]).to eq("test-secret-key")
      expect(params["target_config_content"]).to include("[target]")
    end
  end
end
