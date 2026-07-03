# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::CloneToHost do
  let(:source_vm) { create_archive_ready_vm }
  let(:source_volume) { source_vm.vm_storage_volumes.first }
  let(:target_host) { create_vm_host(location_id: Location::HETZNER_FSN1_ID) }
  let(:project) { source_vm.project }

  let(:assemble_kwargs) {
    {
      source_vm_id: source_vm.id,
      target_vm_host_id: target_host.id,
      project_id: project.id,
      name: "clone-target",
      public_key: "ssh-ed25519 fake",
    }
  }

  before { allow_any_instance_of(VmStorageVolume).to receive(:caught_up?).and_return(true) }

  describe ".assemble" do
    it "creates a strand at 'start' when preconditions are satisfied" do
      st = described_class.assemble(**assemble_kwargs)
      expect(st.prog).to eq("Vm::CloneToHost")
      expect(st.label).to eq("start")
      frame = st.stack.first
      expect(frame["source_vm_id"]).to eq(source_vm.id)
      expect(frame["target_vm_host_id"]).to eq(target_host.id)
      expect(frame["name"]).to eq("clone-target")
      expect(frame["destroy_source_after"]).to be(false)
    end

    it "fails when the source VM does not exist" do
      expect { described_class.assemble(**assemble_kwargs, source_vm_id: Vm.generate_uuid) }
        .to raise_error(Sequel::NoMatchingRow)
    end

    it "fails when the target host does not exist" do
      expect { described_class.assemble(**assemble_kwargs, target_vm_host_id: VmHost.generate_uuid) }
        .to raise_error(Sequel::NoMatchingRow)
    end

    it "fails when the target host is not accepting allocations" do
      target_host.update(allocation_state: "draining")
      expect { described_class.assemble(**assemble_kwargs) }
        .to raise_error("target host is not accepting allocations")
    end

    it "fails when the source has multiple storage volumes" do
      sd = source_vm.vm_host.storage_devices.first
      vbb = source_vm.vm_host.vhost_block_backends.first
      VmStorageVolume.create(
        vm_id: source_vm.id, boot: false, size_gib: 1, disk_index: 1,
        storage_device_id: sd.id, vhost_block_backend_id: vbb.id,
        key_encryption_key_1_id: StorageKeyEncryptionKey.create_random(auth_data: "extra").id,
        vring_workers: 1, track_written: true,
      )
      expect { described_class.assemble(**assemble_kwargs) }
        .to raise_error("source VM must have exactly one storage volume")
    end

    it "fails when the source volume does not have track_written" do
      source_volume.update(track_written: false)
      expect { described_class.assemble(**assemble_kwargs) }
        .to raise_error("source VM's storage volume must have track_written enabled")
    end

    it "fails when the source volume has not caught up" do
      allow_any_instance_of(VmStorageVolume).to receive(:caught_up?).and_return(false)
      expect { described_class.assemble(**assemble_kwargs) }
        .to raise_error("source VM's storage volume has not caught up")
    end
  end

  describe "labels" do
    let(:st) { described_class.assemble(**assemble_kwargs) }
    let(:prog) { described_class.new(st) }
    let(:sshable) { source_vm.vm_host.sshable }

    before { allow_any_instance_of(VmHost).to receive(:sshable).and_return(sshable) }

    describe "#start" do
      it "sets prevent_destroy, stashes PSK and port, hops to setup_source_stripe_server" do
        expect { prog.start }.to hop("setup_source_stripe_server")
        expect(source_vm.reload.prevent_destroy_set?).to be(true)
        frame = prog.strand.stack.first
        expect(frame["psk_kek_id"]).not_to be_nil
        expect(frame["remote_stripe_port"]).to be_between(41000, 41999)
      end
    end

    def seed_started_frame(port: 41234)
      kek = StorageKeyEncryptionKey.create_random(auth_data: "spec")
      refresh_frame(prog, new_values: {"psk_kek_id" => kek.id, "remote_stripe_port" => port})
    end

    describe "#setup_source_stripe_server" do
      it "writes the listen-config and launches remote-stripe-server via d_run" do
        seed_started_frame(port: 41234)
        sv = source_vm.vm_storage_volumes.first
        vbb_version = sv.vhost_block_backend.version
        expected_cfg = "/var/storage/devices/vda/#{source_vm.inhost_name}/0/remote-stripe-listen.conf"
        expected_src = "/var/storage/devices/vda/#{source_vm.inhost_name}/0/vhost-backend.conf"
        expected_bin = "/opt/vhost-block-backend/#{vbb_version}/remote-stripe-server"

        cmd_args = nil
        expect(sshable).to receive(:cmd) { |*args, **kwargs|
          cmd_args = [args, kwargs]
          nil
        }
        expect(sshable).to receive(:d_run).with(
          "clone_stripe_#{source_vm.ubid}",
          "sudo", expected_bin,
          "--config", expected_src,
          "--listen-config", expected_cfg,
        )
        expect { prog.setup_source_stripe_server }.to hop("wait_source_stripe_server")

        expect(cmd_args[0]).to eq(["sudo tee :listen_conf > /dev/null && sudo chmod 600 :listen_conf"])
        expect(cmd_args[1][:listen_conf]).to eq(expected_cfg)
        expect(cmd_args[1][:stdin]).to include("address = \"0.0.0.0:41234\"")
        expect(cmd_args[1][:stdin]).to include("[secrets.remote-psk]")
        expect(cmd_args[1][:log]).to be(false)
      end
    end

    describe "#wait_source_stripe_server" do
      before { seed_started_frame }

      it "hops to create_target_vm when server is InProgress" do
        expect(sshable).to receive(:d_check).and_return("InProgress")
        expect { prog.wait_source_stripe_server }.to hop("create_target_vm")
      end

      it "hops to failed when the server exited before target VM was created" do
        expect(sshable).to receive(:d_check).and_return("Succeeded")
        expect { prog.wait_source_stripe_server }.to hop("failed")
      end

      it "hops to failed when the server failed to start" do
        expect(sshable).to receive(:d_check).and_return("Failed")
        expect { prog.wait_source_stripe_server }.to hop("failed")
      end

      it "naps otherwise" do
        expect(sshable).to receive(:d_check).and_return("NotStarted")
        expect { prog.wait_source_stripe_server }.to nap(5)
      end
    end

    describe "#wait_target_vm" do
      it "naps when the target VM is not running yet" do
        target = create_vm(display_state: "creating")
        refresh_frame(prog, new_values: {"target_vm_id" => target.id})
        expect { prog.wait_target_vm }.to nap(15)
      end

      it "hops to wait_fetch_complete when target VM is running" do
        target = create_vm(display_state: "running")
        refresh_frame(prog, new_values: {"target_vm_id" => target.id})
        expect { prog.wait_target_vm }.to hop("wait_fetch_complete")
      end
    end

    describe "#wait_fetch_complete" do
      let(:target) { create_vm }

      before {
        VmStorageVolume.create(vm_id: target.id, boot: true, size_gib: 5, disk_index: 0)
        refresh_frame(prog, new_values: {"target_vm_id" => target.id})
      }

      it "naps if any target volume has not caught up" do
        allow_any_instance_of(VmStorageVolume).to receive(:caught_up?).and_return(false)
        expect { prog.wait_fetch_complete }.to nap(30)
      end

      it "hops to teardown_source_stripe_server when all target volumes caught up" do
        expect { prog.wait_fetch_complete }.to hop("teardown_source_stripe_server")
      end
    end

    describe "#teardown_source_stripe_server" do
      before {
        source_vm.incr_prevent_destroy
        seed_started_frame
      }

      it "stops the server if in progress, cleans it up, releases prevent_destroy" do
        expect(sshable).to receive(:d_check).with("clone_stripe_#{source_vm.ubid}").and_return("InProgress")
        expect(sshable).to receive(:d_stop).with("clone_stripe_#{source_vm.ubid}")
        expect(sshable).to receive(:d_clean).with("clone_stripe_#{source_vm.ubid}")
        expect { prog.teardown_source_stripe_server }.to hop("finish")
        expect(source_vm.reload.prevent_destroy_set?).to be(false)
      end

      it "skips d_stop if server already exited" do
        expect(sshable).to receive(:d_check).and_return("Succeeded")
        expect(sshable).not_to receive(:d_stop)
        expect(sshable).to receive(:d_clean)
        expect { prog.teardown_source_stripe_server }.to hop("finish")
      end

      it "schedules source destroy when destroy_source_after is set" do
        refresh_frame(prog, new_values: {"destroy_source_after" => true})
        expect(sshable).to receive(:d_check).and_return("Succeeded")
        expect(sshable).to receive(:d_clean)
        expect { prog.teardown_source_stripe_server }.to hop("finish")
        expect(source_vm.reload.destroy_set?).to be(true)
      end
    end

    describe "#finish" do
      it "pops with target_vm_id" do
        refresh_frame(prog, new_values: {"target_vm_id" => "some-target-id"})
        expect { prog.finish }.to exit({"target_vm_id" => "some-target-id"})
      end
    end

    describe "#failed" do
      it "naps" do
        expect { prog.failed }.to nap(15)
      end
    end
  end
end
