# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::CreateBaseVersion do
  let(:image_project) { Project.create(name: "machine-images-service") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:machine_image) { MachineImage.create(project_id: image_project.id, location_id:, name: "ubuntu-jammy", arch: "x64") }
  let(:version) { "20240319" }
  let(:sha256sum) { Prog::DownloadBootImage::BOOT_IMAGE_SHA256.dig("ubuntu-jammy", "x64", version) }
  let(:url) { Prog::DownloadBootImage.upstream_url("ubuntu-jammy", version, "x64") }

  let(:strand) {
    Strand.create(prog: "MachineImage::CreateBaseVersion", label: "create_version", stack: [{
      "machine_image_id" => machine_image.id,
      "version" => version,
      "url" => url,
      "sha256sum" => sha256sum,
    }])
  }
  let(:prog) { described_class.new(strand) }

  before do
    allow(Config).to receive(:machine_images_service_project_id).and_return(image_project.id)
    MachineImageStore.create(project_id: image_project.id, location_id:, provider: "r2", region: "auto",
      endpoint: "https://r2.example.com/", bucket: "b", access_key: "ak", secret_key: "sk")
    machine_image
  end

  def create_version_records(status: "creating", actual_size_mib: 2048)
    miv = MachineImageVersion.create(machine_image_id: machine_image.id, version:, actual_size_mib:)
    kek = StorageKeyEncryptionKey.create_random(auth_data: "test")
    store = MachineImageStore.first(project_id: image_project.id, location_id:)
    MachineImageVersionMetal.create_with_id(miv, status:, archive_size_mib: (status == "ready") ? 1 : nil,
      archive_kek_id: kek.id, store_id: store.id, store_prefix: "p")
    Strand.create_with_id(miv, prog: "MachineImage::VersionMetalNexus", label: "wait", stack: [{}])
    miv
  end

  describe ".assemble" do
    it "creates a strand with the url and sha pulled from the boot image catalog" do
      st = described_class.assemble(name: "ubuntu-jammy", version:, location_id:)
      expect(st.label).to eq "create_version"
      frame = st.stack.first
      expect(frame["machine_image_id"]).to eq machine_image.id
      expect(frame["version"]).to eq version
      expect(frame["sha256sum"]).to eq sha256sum
      expect(frame["url"]).to eq url
    end

    it "fails when no machine images service project is configured" do
      allow(Config).to receive(:machine_images_service_project_id).and_return(nil)
      expect { described_class.assemble(name: "ubuntu-jammy", version:, location_id:) }
        .to raise_error(MachineImageError, /no machine images service project configured/)
    end

    it "fails when the machine image does not exist" do
      expect { described_class.assemble(name: "ubuntu-noble", version:, location_id:) }
        .to raise_error(MachineImageError, /machine image "ubuntu-noble" does not exist/)
    end

    it "fails for a version that is not in the boot image catalog" do
      expect { described_class.assemble(name: "ubuntu-jammy", version: "00000000", location_id:) }
        .to raise_error(MachineImageError, /unknown base boot image version/)
    end

    it "fails when there is no machine image store for the location" do
      MachineImageStore.dataset.destroy
      expect { described_class.assemble(name: "ubuntu-jammy", version:, location_id:) }
        .to raise_error(MachineImageError, /no machine image store/)
    end

    it "fails when the version already exists" do
      MachineImageVersion.create(machine_image_id: machine_image.id, version:, actual_size_mib: nil)
      expect { described_class.assemble(name: "ubuntu-jammy", version:, location_id:) }
        .to raise_error(MachineImageError, /already exists/)
    end
  end

  describe "#create_version" do
    it "creates a not-yet-latest version from the url and hops to wait_version" do
      miv = create_version_records
      expect(Prog::MachineImage::VersionMetalNexus).to receive(:assemble_from_url)
        .with(machine_image, version, url, sha256sum, instance_of(MachineImageStore), set_as_latest: false)
        .and_return(miv)

      expect { prog.create_version }.to hop("wait_version")
      expect(prog.strand.stack.first["machine_image_version_id"]).to eq miv.id
    end
  end

  describe "#wait_version" do
    it "naps while the version is still being archived" do
      prog.machine_image_version_id = create_version_records(status: "creating").id
      expect { prog.wait_version }.to nap(15)
    end

    it "hops to create_test_vm when the version is ready" do
      prog.machine_image_version_id = create_version_records(status: "ready").id
      expect { prog.wait_version }.to hop("create_test_vm")
    end

    it "hops to failed when the archive failed" do
      prog.machine_image_version_id = create_version_records(status: "failed").id
      expect { prog.wait_version }.to hop("failed")
    end
  end

  describe "#create_test_vm" do
    it "boots a test vm from the new version and hops to wait_test_vm" do
      miv = create_version_records(status: "ready", actual_size_mib: 20480)
      prog.machine_image_version_id = miv.id
      vm_strand = instance_double(Strand, id: Strand.generate_uuid)
      expect(Prog::Vm::Nexus).to receive(:assemble_with_sshable)
        .with(image_project.id, hash_including(
          sshable_unix_user: "ubi",
          location_id:,
          arch: "x64",
          enable_ip4: true,
          storage_volumes: [{encrypted: true, size_gib: 20, machine_image_version_id: miv.id}],
        )).and_return(vm_strand)

      expect { prog.create_test_vm }.to hop("wait_test_vm")
      expect(prog.strand.stack.first["test_vm_id"]).to eq vm_strand.id
      expect(prog.strand.stack.first["deadline_target"]).to eq "set_latest"
    end

    it "uses a floor of 10 GiB for the boot disk" do
      miv = create_version_records(status: "ready", actual_size_mib: 2048)
      prog.machine_image_version_id = miv.id
      expect(Prog::Vm::Nexus).to receive(:assemble_with_sshable)
        .with(image_project.id, hash_including(storage_volumes: [{encrypted: true, size_gib: 10, machine_image_version_id: miv.id}]))
        .and_return(instance_double(Strand, id: Strand.generate_uuid))
      expect { prog.create_test_vm }.to hop("wait_test_vm")
    end
  end

  describe "#wait_test_vm" do
    let(:test_vm) { instance_double(Vm) }

    before { allow(prog).to receive(:test_vm).and_return(test_vm) }

    it "naps until the test vm is running" do
      expect(test_vm).to receive(:display_state).and_return("creating")
      expect { prog.wait_test_vm }.to nap(10)
    end

    it "hops to verify once the test vm is running" do
      expect(test_vm).to receive(:display_state).and_return("running")
      expect { prog.wait_test_vm }.to hop("verify")
    end
  end

  describe "#verify" do
    let(:sshable) { Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair) }
    let(:test_vm) { instance_double(Vm, sshable:) }

    before do
      allow(prog).to receive(:test_vm).and_return(test_vm)
      prog.machine_image_version_id = create_version_records(status: "ready").id
    end

    it "naps until the test vm is reachable" do
      expect(sshable).to receive(:available?).and_return(false)
      expect { prog.verify }.to nap(10)
    end

    it "runs verification commands and hops to set_latest" do
      expect(sshable).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).with("cat /etc/os-release")
      expect(sshable).to receive(:_cmd).with("sudo true")
      expect { prog.verify }.to hop("set_latest")
    end

    it "retries a few times when a command fails" do
      expect(sshable).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).and_raise(Sshable::SshError.new("cmd", "", "boom", 1, nil))
      expect { prog.verify }.to nap(10)
      expect(prog.strand.stack.first["verify_failures"]).to eq 1
    end

    it "hops to failed after too many command failures" do
      prog.verify_failures = described_class::MAX_VERIFY_FAILURES - 1
      expect(sshable).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).and_raise(Sshable::SshError.new("cmd", "", "boom", 1, nil))
      expect { prog.verify }.to hop("failed")
    end
  end

  describe "#set_latest" do
    let(:test_vm) { instance_double(Vm) }

    before { allow(prog).to receive(:test_vm).and_return(test_vm) }

    it "promotes the version to latest and destroys the test vm" do
      miv = create_version_records(status: "ready")
      prog.machine_image_version_id = miv.id
      expect(test_vm).to receive(:incr_destroy)

      expect { prog.set_latest }.to exit({"msg" => "base machine image version created", "machine_image_version_id" => miv.id})
      expect(machine_image.reload.latest_version_id).to eq miv.id
    end

    it "does not promote a version that is no longer ready" do
      miv = create_version_records(status: "creating")
      prog.machine_image_version_id = miv.id
      expect(test_vm).to receive(:incr_destroy)

      expect { prog.set_latest }.to exit
      expect(machine_image.reload.latest_version_id).to be_nil
    end

    it "does not crash when the version metal was destroyed while testing" do
      miv = create_version_records(status: "ready")
      prog.machine_image_version_id = miv.id
      miv.metal.destroy
      expect(test_vm).to receive(:incr_destroy)

      expect { prog.set_latest }.to exit
      expect(machine_image.reload.latest_version_id).to be_nil
    end
  end

  describe "#failed" do
    it "naps for inspection" do
      expect { prog.failed }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "destroys the version and the test vm and pops" do
      miv = create_version_records
      prog.machine_image_version_id = miv.id
      test_vm = instance_double(Vm)
      allow(prog).to receive(:test_vm).and_return(test_vm)
      expect(test_vm).to receive(:incr_destroy)

      expect { prog.destroy }.to exit({"msg" => "base machine image version creation destroyed"})
      expect(Semaphore.where(strand_id: miv.id, name: "destroy").count).to eq 1
    end

    it "pops even when nothing was created yet" do
      expect { prog.destroy }.to exit({"msg" => "base machine image version creation destroyed"})
    end
  end
end
