# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::CreateVersionMetalFromUrl do
  subject(:prog) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-mi-project") }
  let(:vm_host) { create_vm_host }
  let(:machine_image) { MachineImage.create(name: "test-image", arch: "x64", project_id: project.id, location_id: Location::HETZNER_FSN1_ID) }
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
      version: "1.0",
      actual_size_mib: 0
    )
  }
  let(:archive_kek) { StorageKeyEncryptionKey.create_random(auth_data: "target-kek") }
  let(:mi_version_metal) {
    MachineImageVersionMetal.create_with_id(
      mi_version,
      enabled: false,
      archive_kek_id: archive_kek.id,
      store_id: store.id,
      store_prefix: "#{project.ubid}/#{machine_image.ubid}/1.0"
    )
  }
  let(:strand) {
    Strand.create_with_id(
      mi_version_metal,
      prog: "MachineImage::CreateVersionMetalFromUrl",
      label: "archive",
      stack: [{
        "subject_id" => mi_version_metal.id,
        "vm_host_id" => vm_host.id,
        "url" => "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
        "sha256" => "abc123",
        "set_as_latest" => true
      }]
    )
  }

  describe ".assemble" do
    it "creates a machine image version metal and strand" do
      new_mi_version = MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version: "2.0",
        actual_size_mib: 0
      )

      strand = described_class.assemble(new_mi_version, "https://example.com/image.img", "sha256hash", store, vm_host)

      mi_version_metal = MachineImageVersionMetal[strand.id]
      expect(mi_version_metal).not_to be_nil
      expect(mi_version_metal.enabled).to be false
      expect(mi_version_metal.store_id).to eq(store.id)
      expect(mi_version_metal.store_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/2.0")
      expect(mi_version_metal.archive_kek).not_to be_nil

      expect(strand.prog).to eq("MachineImage::CreateVersionMetalFromUrl")
      expect(strand.label).to eq("archive")
      expect(strand.stack.first["vm_host_id"]).to eq(vm_host.id)
      expect(strand.stack.first["url"]).to eq("https://example.com/image.img")
      expect(strand.stack.first["sha256"]).to eq("sha256hash")
      expect(strand.stack.first["set_as_latest"]).to be true
    end

    it "respects set_as_latest: false" do
      new_mi_version = MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version: "3.0",
        actual_size_mib: 0
      )

      strand = described_class.assemble(new_mi_version, "https://example.com/image.img", "sha256hash", store, vm_host, set_as_latest: false)

      expect(strand.stack.first["set_as_latest"]).to be false
    end
  end

  describe "#archive" do
    let(:sshable) { vm_host.sshable }
    let(:daemon_name) { "archive_url_#{mi_version.ubid}" }

    before do
      allow(prog).to receive(:archive_params_json).and_return('{"target_conf":"value"}')
      allow(VmHost).to receive(:[]).with(vm_host.id).and_return(vm_host)
    end

    it "hops to read_result when daemon succeeded" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Succeeded")

      expect { prog.archive }.to hop("read_result")
    end

    it "restarts daemon when it failed" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Failed")
      expect(sshable).to receive(:d_restart).with(daemon_name)
      expect { prog.archive }.to nap(60)
    end

    it "starts daemon when status is NotStarted" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-url",
        "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
        "abc123", "v0.4.0",
        stdin: '{"target_conf":"value"}', log: false)

      expect { prog.archive }.to nap(30)
    end

    it "naps when daemon is still running" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("InProgress")

      expect { prog.archive }.to nap(30)
    end

    it "logs unexpected status" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Unknown")
      expect(Clog).to receive(:emit).with("Unexpected daemonizer2 status: Unknown")

      expect { prog.archive }.to nap(60)
    end
  end

  describe "#read_result" do
    let(:sshable) { vm_host.sshable }
    let(:daemon_name) { "archive_url_#{mi_version.ubid}" }

    before do
      allow(VmHost).to receive(:[]).with(vm_host.id).and_return(vm_host)
    end

    it "reads image_size_mib from journal and hops to finish" do
      expect(sshable).to receive(:cmd).with("sudo journalctl -u :unit_name.service --output=cat --no-pager | grep image_size_mib", unit_name: daemon_name).and_return('{"image_size_mib":605}')
      expect(sshable).to receive(:d_clean).with(daemon_name)

      expect { prog.read_result }.to hop("finish")

      strand.reload
      expect(strand.stack.first["image_size_mib"]).to eq(605)
    end
  end

  describe "#finish" do
    before do
      allow(prog).to receive(:archive_size_bytes).and_return(10 * 1024 * 1024)
      refresh_frame(prog, new_values: {"image_size_mib" => 605})
    end

    it "enables machine image version metal and sets sizes" do
      expect { prog.finish }.to exit({"msg" => "machine image version created from url"})

      mi_version_metal.reload
      mi_version.reload
      expect(mi_version_metal.enabled).to be true
      expect(mi_version_metal.archive_size_mib).to eq(10)
      expect(mi_version.actual_size_mib).to eq(605)
    end

    it "sets machine image latest version when configured" do
      refresh_frame(prog, new_values: {"set_as_latest" => true, "image_size_mib" => 605})

      expect { prog.finish }.to exit({"msg" => "machine image version created from url"})

      machine_image.reload
      expect(machine_image.latest_version_id).to eq(mi_version.id)
    end

    it "does not set latest version when set_as_latest is false" do
      refresh_frame(prog, new_values: {"set_as_latest" => false, "image_size_mib" => 605})

      expect { prog.finish }.to exit({"msg" => "machine image version created from url"})

      machine_image.reload
      expect(machine_image.latest_version_id).to be_nil
    end
  end

  describe "#archive_params_json" do
    it "generates JSON payload with store credentials" do
      allow(VmHost).to receive(:[]).with(vm_host.id).and_return(vm_host)

      result = JSON.parse(prog.send(:archive_params_json))

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
