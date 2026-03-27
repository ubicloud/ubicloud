# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::BurnPostgresImage do
  subject(:prog) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-burn-project") }
  let(:vm_host) { create_vm_host }
  let(:machine_image) { MachineImage.create(name: "postgres-16", arch: "x64", project_id: project.id, location_id: Location::HETZNER_FSN1_ID) }
  let(:store) {
    MachineImageStore.create(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      provider: "minio",
      region: "eu",
      endpoint: "https://minio.example.com/",
      bucket: "test-bucket",
      access_key: "test-access-key",
      secret_key: "test-secret-key"
    )
  }
  let(:mi_version) {
    MachineImageVersion.create(
      machine_image_id: machine_image.id,
      version: "20250101.120000"
    )
  }
  let(:archive_kek) { StorageKeyEncryptionKey.create_random(auth_data: "burn-kek") }
  let(:mi_version_metal) {
    MachineImageVersionMetal.create_with_id(
      mi_version,
      enabled: false,
      archive_kek_id: archive_kek.id,
      store_id: store.id,
      store_prefix: "#{project.ubid}/#{machine_image.ubid}/20250101.120000"
    )
  }
  let(:temp_vm) {
    vm = create_vm(vm_host_id: vm_host.id, project_id: project.id, name: "burn-pg16-test")
    sd = StorageDevice.create(name: "vda", total_storage_gib: 100, available_storage_gib: 50, vm_host_id: vm_host.id)
    be = VhostBlockBackend.create(version: "v0.4.0", allocation_weight: 50, vm_host_id: vm_host.id)
    VmStorageVolume.create(
      vm_id: vm.id, boot: true, size_gib: 40, disk_index: 0,
      storage_device_id: sd.id, vhost_block_backend_id: be.id,
      key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "test-vm-kek").id,
      vring_workers: 1
    )
    Sshable.create_with_id(vm, unix_user: "ubi", host: "temp_test", raw_private_key_1: SshKey.generate.keypair)
    vm
  }
  let(:strand) {
    Strand.create_with_id(
      mi_version_metal,
      prog: "MachineImage::BurnPostgresImage",
      label: "wait_vm_running",
      stack: [{
        "subject_id" => mi_version_metal.id,
        "vm_id" => temp_vm.id,
        "vm_host_id" => vm_host.id,
        "postgres_version" => "16",
        "set_as_latest" => true
      }]
    )
  }

  describe ".assemble" do
    it "creates machine image version, metal record, vm, and strand" do
      strand = described_class.assemble(machine_image, store,
        vm_host_id: vm_host.id, postgres_version: "16", version: "20250102.000000")

      miv_metal = MachineImageVersionMetal[strand.id]
      expect(miv_metal).not_to be_nil
      expect(miv_metal.enabled).to be false
      expect(miv_metal.store_id).to eq(store.id)
      expect(miv_metal.store_prefix).to start_with("#{project.ubid}/#{machine_image.ubid}/20250102.000000")
      expect(miv_metal.archive_kek).not_to be_nil

      expect(strand.prog).to eq("MachineImage::BurnPostgresImage")
      expect(strand.label).to eq("wait_vm_running")
      expect(strand.stack.first["postgres_version"]).to eq("16")
      expect(strand.stack.first["vm_id"]).not_to be_nil
    end

    it "generates a timestamp version when none provided" do
      strand = described_class.assemble(machine_image, store,
        vm_host_id: vm_host.id, postgres_version: "16")

      expect(MachineImageVersionMetal[strand.id].machine_image_version.version).to match(/\d{8}\.\d{6}/)
    end
  end

  describe "#wait_vm_running" do
    let(:vm_strand) { Strand.create_with_id(temp_vm, prog: "Vm::Metal::Nexus", label: "wait") }

    before do
      allow(prog).to receive(:temp_vm).and_return(temp_vm)
    end

    it "hops to install_postgres when VM is running and SSH accessible" do
      allow(temp_vm).to receive(:strand).and_return(vm_strand)
      allow(prog).to receive(:temp_vm_sshable?).and_return(true)

      expect { prog.wait_vm_running }.to hop("install_postgres")
    end

    it "naps when VM strand is not in wait state" do
      vm_strand.update(label: "prep")
      allow(temp_vm).to receive(:strand).and_return(vm_strand)

      expect { prog.wait_vm_running }.to nap(15)
    end

    it "naps when VM is not SSH accessible" do
      allow(temp_vm).to receive(:strand).and_return(vm_strand)
      allow(prog).to receive(:temp_vm_sshable?).and_return(false)

      expect { prog.wait_vm_running }.to nap(15)
    end
  end

  describe "#install_postgres" do
    before do
      allow(prog).to receive(:temp_vm).and_return(temp_vm)
    end

    it "uploads and runs the full-stack build script via SSH and hops to stop_vm" do
      expect(File).to receive(:read).with(a_string_matching(%r{rhizome/postgres/bin/build-postgres-image})).and_return("#!/bin/bash\necho build")
      expect(temp_vm.sshable).to receive(:cmd).with(
        "sudo bash -s -- :pg_version",
        pg_version: "16",
        stdin: "#!/bin/bash\necho build",
        timeout: 30 * 60
      )

      expect { prog.install_postgres }.to hop("stop_vm")
    end
  end

  describe "#stop_vm" do
    before do
      allow(prog).to receive(:temp_vm).and_return(temp_vm)
    end

    it "increments stop semaphore and hops to wait_vm_stopped" do
      expect(temp_vm).to receive(:incr_stop)
      expect { prog.stop_vm }.to hop("wait_vm_stopped")
    end
  end

  describe "#wait_vm_stopped" do
    before do
      allow(prog).to receive(:temp_vm).and_return(temp_vm)
    end

    it "hops to archive when VM is stopped" do
      vm_strand = Strand.create_with_id(temp_vm, prog: "Vm::Metal::Nexus", label: "stopped")
      allow(temp_vm).to receive(:strand).and_return(vm_strand)

      expect { prog.wait_vm_stopped }.to hop("archive")
    end

    it "naps when VM is not yet stopped" do
      vm_strand = Strand.create_with_id(temp_vm, prog: "Vm::Metal::Nexus", label: "wait")
      allow(temp_vm).to receive(:strand).and_return(vm_strand)

      expect { prog.wait_vm_stopped }.to nap(10)
    end
  end

  describe "#archive" do
    let(:sshable) { vm_host.sshable }
    let(:daemon_name) { "archive_#{mi_version.ubid}" }

    before do
      allow(prog).to receive_messages(archive_params_json: '{"field":"value"}', temp_vm: temp_vm, vm_host: vm_host)
    end

    it "cleans daemon and hops to finish when daemon succeeded" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with(daemon_name)

      expect { prog.archive }.to hop("finish")
    end

    it "restarts daemon when it failed" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Failed")
      expect(sshable).to receive(:d_restart).with(daemon_name)
      expect { prog.archive }.to nap(60)
    end

    it "starts daemon when status is NotStarted" do
      sv = temp_vm.vm_storage_volumes.first
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-storage-volume",
        temp_vm.inhost_name, sv.storage_device.name, sv.disk_index, sv.vhost_block_backend.version,
        stdin: '{"field":"value"}', log: false)

      expect { prog.archive }.to nap(30)
    end

    it "naps when daemon is still running" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("InProgress")
      expect { prog.archive }.to nap(30)
    end

    it "handles unexpected daemon status" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("UnknownStatus")
      expect(Clog).to receive(:emit).with("Unexpected daemonizer2 status: UnknownStatus")
      expect { prog.archive }.to nap(60)
    end
  end

  describe "#finish" do
    before do
      allow(prog).to receive_messages(archive_size_bytes: 10 * 1024 * 1024, temp_vm: temp_vm)
    end

    it "enables version, updates sizes, sets latest_version_id, destroys VM, and pops" do
      expect(temp_vm).to receive(:incr_destroy)

      expect { prog.finish }.to exit({"msg" => "postgres image burned and archived"})

      mi_version_metal.reload
      mi_version.reload
      machine_image.reload
      expect(mi_version_metal.enabled).to be true
      expect(mi_version_metal.archive_size_mib).to eq(10)
      expect(mi_version.actual_size_mib).to eq(40960)
      expect(machine_image.latest_version_id).to eq(mi_version.id)
    end

    it "does not set latest_version_id when set_as_latest is false" do
      refresh_frame(prog, new_values: {"set_as_latest" => false})
      expect(temp_vm).to receive(:incr_destroy)

      expect { prog.finish }.to exit({"msg" => "postgres image burned and archived"})

      machine_image.reload
      expect(machine_image.latest_version_id).to be_nil
    end
  end

  describe "#archive_params_json" do
    it "generates JSON payload with store and VM KEK credentials" do
      allow(Vm).to receive(:[]).with(temp_vm.id).and_return(temp_vm)

      result = JSON.parse(prog.send(:archive_params_json))
      sv = temp_vm.vm_storage_volumes.first

      expect(result["kek"]).to eq(sv.key_encryption_key_1.secret_key_material_hash)
      expect(result["target_conf"]).to include(
        "endpoint" => store.endpoint,
        "region" => store.region,
        "bucket" => store.bucket,
        "prefix" => mi_version_metal.store_prefix,
        "access_key_id" => store.access_key,
        "secret_access_key" => store.secret_key,
        "archive_kek" => archive_kek.secret_key_material_hash
      )
    end
  end

  describe "#archive_size_bytes" do
    it "sums object sizes across pages" do
      s3 = Aws::S3::Client.new(stub_responses: true)
      s3.stub_responses(
        :list_objects_v2,
        {contents: [{size: 10}, {size: 20}], is_truncated: true, next_continuation_token: "token"},
        {contents: [{size: 5}], is_truncated: false}
      )

      allow(Aws::S3::Client).to receive(:new).with(
        region: store.region,
        endpoint: store.endpoint,
        access_key_id: store.access_key,
        secret_access_key: store.secret_key
      ).and_return(s3)

      expect(prog.send(:archive_size_bytes)).to eq(35)
    end
  end
end
