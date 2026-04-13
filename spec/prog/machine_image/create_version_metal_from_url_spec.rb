# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::MachineImage::CreateVersionMetalFromUrl do
  subject(:prog) { described_class.new(strand) }

  let(:vm_host) { create_vm_host }
  let(:mi_version_metal) { create_machine_image_version_metal }
  let(:project) { machine_image.project }
  let(:mi_version) { mi_version_metal.machine_image_version }
  let(:machine_image) { mi_version.machine_image }
  let(:store) { mi_version_metal.store }
  let(:archive_kek) { mi_version_metal.archive_kek }
  let(:url) { "https://example.com/image.raw" }
  let(:sha256sum) { "abc123" }
  let(:strand) {
    vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 1, vm_host_id: vm_host.id)
    Strand.create_with_id(
      mi_version_metal,
      prog: "MachineImage::CreateVersionMetalFromUrl",
      label: "archive",
      stack: [{
        "subject_id" => mi_version_metal.id,
        "url" => url,
        "sha256sum" => sha256sum,
        "vm_host_id" => vm_host.id,
        "vhost_block_backend_version" => vbb.version,
        "set_as_latest" => false,
      }],
    )
  }

  describe ".assemble" do
    it "creates a machine image version metal and strand" do
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 50, vm_host_id: vm_host.id)
      strand = described_class.assemble(machine_image, "2.0", url, sha256sum, store)

      mi_version_metal = MachineImageVersionMetal[strand.id]
      expect(mi_version_metal).not_to be_nil
      expect(mi_version_metal.enabled).to be false
      expect(mi_version_metal.store_id).to eq(store.id)
      expect(mi_version_metal.store_prefix).to eq("#{project.ubid}/#{machine_image.ubid}/2.0")
      expect(mi_version_metal.archive_kek).not_to be_nil

      expect(strand.prog).to eq("MachineImage::CreateVersionMetalFromUrl")
      expect(strand.label).to eq("archive")
      expect(strand.stack.first["url"]).to eq(url)
      expect(strand.stack.first["sha256sum"]).to eq(sha256sum)
      expect(strand.stack.first["vm_host_id"]).to eq(vm_host.id)
      expect(strand.stack.first["vhost_block_backend_version"]).to eq(vbb.version)
      expect(strand.stack.first["set_as_latest"]).to be true
    end

    it "selects only from backends that support archive" do
      create_vhost_block_backend(version: "v0.3.0", allocation_weight: 5000, vm_host_id: vm_host.id)
      vbb = create_vhost_block_backend(version: "v0.4.1", allocation_weight: 1, vm_host_id: vm_host.id)

      strand = described_class.assemble(machine_image, "2.0", url, sha256sum, store)

      expect(strand.stack.first["vhost_block_backend_version"]).to eq(vbb.version)
    end

    it "fails when no vm host with archive support exists in location" do
      expect {
        described_class.assemble(machine_image, "v0.1", url, sha256sum, store)
      }.to raise_error("no vm host with archive support found in location")
    end
  end

  describe "#archive" do
    let(:sshable) { vm_host.sshable }
    let(:daemon_name) { "archive_#{mi_version.ubid}" }
    let(:stats_path) { "/tmp/archive_stats_#{mi_version.ubid}.json" }

    before do
      allow(prog).to receive(:vm_host).and_return(vm_host)
    end

    it "reads stats, cleans daemon and hops to finish when daemon succeeded" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat #{stats_path}").and_return('{"physical_size_bytes": 10485760, "logical_size_bytes": 1073741824}')
      expect(sshable).to receive(:d_clean).with(daemon_name)

      expect { prog.archive }.to hop("finish")
      expect(strand.stack.first["physical_size_bytes"]).to eq(10485760)
      expect(strand.stack.first["logical_size_bytes"]).to eq(1073741824)
    end

    it "restarts daemon when it failed" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("Failed")
      expect(sshable).to receive(:d_restart).with(daemon_name)
      expect { prog.archive }.to nap(60)
    end

    it "starts daemon when status is NotStarted" do
      expect(sshable).to receive(:d_check).with(daemon_name).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(daemon_name,
        "sudo", "host/bin/archive-url", url, sha256sum, "v0.4.1", stats_path,
        stdin: prog.archive_params_json, log: false)

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
    before {
      refresh_frame(prog, new_values: {"physical_size_bytes" => 10 * 1024 * 1024, "logical_size_bytes" => 20 * 1024 * 1024})
      allow(prog).to receive(:vm_host).and_return(vm_host)
      expect(vm_host.sshable).to receive(:_cmd).with("sudo rm -f /tmp/archive_stats_#{mi_version.ubid}.json")
    }

    it "enables machine image version metal and sets archive size" do
      expect { prog.finish }.to exit({"msg" => "Metal machine image version is created and enabled"})

      mi_version_metal.reload
      machine_image.reload
      expect(mi_version_metal.enabled).to be true
      expect(mi_version_metal.archive_size_mib).to eq(10)
      expect(mi_version.reload.actual_size_mib).to eq(20)
    end

    it "sets machine image latest version when configured" do
      refresh_frame(prog, new_values: {"set_as_latest" => true})

      expect { prog.finish }.to exit({"msg" => "Metal machine image version is created and enabled"})

      machine_image.reload
      expect(machine_image.latest_version.id).to eq(mi_version_metal.id)
    end
  end

  describe "#archive_params_json" do
    it "generates JSON payload with store credentials" do
      result = JSON.parse(prog.archive_params_json)

      expect(result["target_conf"]).to include(
        "endpoint" => store.endpoint,
        "region" => store.region,
        "bucket" => store.bucket,
        "prefix" => mi_version_metal.store_prefix,
        "access_key_id" => store.access_key,
        "secret_access_key" => store.secret_key,
        "archive_kek" => archive_kek.secret_key_material_hash,
      )
    end
  end

  describe "#stats_file_path" do
    it "returns the expected path" do
      expect(prog.stats_file_path).to eq("/tmp/archive_stats_#{mi_version.ubid}.json")
    end
  end

  describe "#vm_host" do
    it "returns the vm host from the frame" do
      vm_host = create_vm_host
      refresh_frame(prog, new_values: {"vm_host_id" => vm_host.id})
      expect(prog.vm_host).to eq(vm_host)
    end
  end
end
