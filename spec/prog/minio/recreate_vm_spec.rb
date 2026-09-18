# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::RecreateVm do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Minio::RecreateVm", label: "start", stack: [{"subject_id" => minio_server.id}]) }
  let(:minio_project) { Project.create(name: "default") }
  let(:minio_cluster) {
    ps = Prog::Vnet::SubnetNexus.assemble(minio_project.id, name: "minio-cluster-name").subject
    MinioCluster.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      private_subnet_id: ps.id,
      project_id: minio_project.id,
      root_cert_1: "root_cert_1",
      root_cert_2: "root_cert_2",
    )
  }
  let(:minio_pool) {
    MinioPool.create(
      start_index: 0,
      cluster_id: minio_cluster.id,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100,
      vm_size: "standard-2",
    )
  }
  let(:minio_server) { Prog::Minio::MinioServerNexus.assemble(minio_pool.id, 0).subject }
  let(:vm) { minio_server.vm }
  let(:vm_host) { create_vm_host }
  let(:address) { Address.create(cidr: "1.2.3.0/30", routed_to_host_id: vm_host.id) }
  let(:info_url) { "https://1.2.3.4:9000/minio/admin/v3/info" }

  before do
    allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
    vm.update(vm_host_id: vm_host.id)
    AssignedVmAddress.create(dst_vm_id: vm.id, ip: "1.2.3.4", address_id: address.id)
  end

  def stub_info(servers)
    stub_request(:get, info_url).to_return(status: 200, body: JSON.generate({servers:}))
  end

  describe ".assemble" do
    it "fails if the minio server does not exist" do
      expect { described_class.assemble(MinioServer.generate_uuid) }.to raise_error RuntimeError, "No existing minio server"
    end

    it "fails if a server is offline" do
      stub_info([{state: "offline", endpoint: "1.2.3.4:9000"}])
      expect { described_class.assemble(minio_server.id) }.to raise_error RuntimeError, "Minio cluster is not healthy"
    end

    it "fails if a drive is not ok" do
      stub_info([{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "offline"}]}])
      expect { described_class.assemble(minio_server.id) }.to raise_error RuntimeError, "Minio cluster is not healthy"
    end

    it "fails if a drive is in healing" do
      stub_info([{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok", healing: true}]}])
      expect { described_class.assemble(minio_server.id) }.to raise_error RuntimeError, "Minio cluster is not healthy"
    end

    it "fails if a server of the cluster is in provisioning" do
      stub_info([{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok"}]}])
      minio_server.incr_initial_provisioning
      expect { described_class.assemble(minio_server.id) }.to raise_error RuntimeError, "Another minio server of the cluster is in provisioning"
      expect(Strand.where(prog: "Minio::RecreateVm").count).to eq 0
    end

    it "sets initial_provisioning and creates the strand" do
      stub_info([{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok"}]}])
      st = described_class.assemble(minio_server.id)
      expect(st.label).to eq "start"
      expect(st.stack).to eq [{"subject_id" => minio_server.id}]
      expect(Semaphore.where(strand_id: minio_server.id, name: "initial_provisioning").count).to eq 1
    end
  end

  describe "#start" do
    it "creates the same vm on the same host with the same ip4 address and destroys the old vm" do
      vm.vm_storage_volumes.each_with_index do |volume, i|
        device = StorageDevice.create(vm_host_id: vm_host.id, name: "stor#{i}", available_storage_gib: 200, total_storage_gib: 200)
        volume.update(storage_device_id: device.id, track_written: i == 0)
      end
      old_vm_id = vm.id

      expect { nx.start }.to hop("wait_vm")

      new_vm = minio_server.reload.vm
      expect(new_vm.id).not_to eq old_vm_id
      expect(new_vm.values.slice(:name, :project_id, :location_id, :unix_user, :family, :vcpus, :arch, :boot_image, :ip4_enabled))
        .to eq(name: minio_server.ubid, project_id: minio_project.id, location_id: Location::HETZNER_FSN1_ID, unix_user: "ubi", family: "standard", vcpus: 2, arch: "x64", boot_image: "ubuntu-jammy", ip4_enabled: true)
      expect(new_vm.sshable.unix_user).to eq "ubi"
      expect(new_vm.private_subnets.map(&:id)).to eq [minio_cluster.private_subnet_id]
      expect(new_vm.vm_storage_volumes_dataset.order(:disk_index).select_map([:boot, :size_gib, :track_written])).to eq [[true, 30, true], [false, 100, false]]
      expect(new_vm.vm_storage_volumes.map(&:key_encryption_key_1_id)).to all(be_a(String))

      frame = new_vm.strand.stack.first
      expect(frame["force_host_id"]).to eq vm_host.id
      expect(frame["keep_ip4"]).to be true
      expect(frame["distinct_storage_devices"]).to be true

      expect(AssignedVmAddress.select_map([:dst_vm_id, :ip]).map { |id, ip| [id, ip.to_s] }).to eq [[new_vm.id, "1.2.3.4/32"]]
      expect(Vm[old_vm_id].name).to eq "#{minio_server.ubid}-old"
      expect(Semaphore.where(strand_id: old_vm_id, name: "destroy").count).to eq 1
      expect(st.stack.first["deadline_target"]).to be_nil
      expect(Time.new(st.stack.first["deadline_at"])).to be_within(5).of(Time.now + 30 * 60)
    end

    it "does not ask for distinct storage devices if the old vm does not have them" do
      device = StorageDevice.create(vm_host_id: vm_host.id, name: "stor0", available_storage_gib: 200, total_storage_gib: 200)
      vm.vm_storage_volumes_dataset.update(storage_device_id: device.id)

      expect { nx.start }.to hop("wait_vm")
      expect(minio_server.reload.vm.strand.stack.first["distinct_storage_devices"]).to be false
    end
  end

  describe "#wait_vm" do
    it "naps if the vm is not ready" do
      expect { nx.wait_vm }.to nap(5)
    end

    it "hops to bootstrap_rhizome if the vm is ready" do
      vm.strand.update(label: "wait")
      expect { nx.wait_vm }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds BootstrapRhizome and hops to wait_bootstrap_rhizome" do
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
      child = st.children_dataset.first
      expect(child.prog).to eq "BootstrapRhizome"
      expect(child.stack).to eq [{"subject_id" => vm.id, "target_folder" => "minio", "user" => "ubi"}]
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "naps if bootstrap rhizome continues" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(120)
    end

    it "hops to create_minio_user if bootstrap rhizome is done" do
      expect { nx.wait_bootstrap_rhizome }.to hop("create_minio_user")
    end
  end

  describe "#create_minio_user" do
    it "creates the minio user and hops to setup" do
      expect(nx.vm.sshable).to receive(:_cmd).with("sudo groupadd -f --system minio-user")
      expect(nx.vm.sshable).to receive(:_cmd).with("id -u minio-user || sudo useradd --no-create-home --system -g minio-user minio-user")
      expect { nx.create_minio_user }.to hop("setup")
    end
  end

  describe "#setup" do
    it "buds the minio setup progs and hops to wait_setup" do
      expect { nx.setup }.to hop("wait_setup")
      expect(st.children_dataset.select_order_map([:prog, :label])).to eq [
        ["Minio::SetupMinio", "configure_minio"],
        ["Minio::SetupMinio", "install_minio"],
        ["Minio::SetupMinio", "mount_data_disks"],
      ]
      expect(st.children.map { it.stack.first["subject_id"] }.uniq).to eq [minio_server.id]
    end
  end

  describe "#wait_setup" do
    it "naps if setup continues" do
      Strand.create(parent_id: st.id, prog: "Minio::SetupMinio", label: "install_minio", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_setup }.to nap(120)
    end

    it "hops to start_minio if setup is done" do
      expect { nx.wait_setup }.to hop("start_minio")
    end
  end

  describe "#start_minio" do
    it "hops to wait_online if minio is started" do
      expect(nx.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check start_minio").and_return("Succeeded")
      expect(nx.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --clean start_minio")
      expect { nx.start_minio }.to hop("wait_online")
    end

    it "starts minio if it is not started" do
      expect(nx.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check start_minio").and_return("NotStarted")
      expect(nx.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer 'systemctl start minio' start_minio")
      expect { nx.start_minio }.to nap(1)
    end

    it "starts minio again if the start failed" do
      expect(nx.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check start_minio").and_return("Failed")
      expect(nx.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer 'systemctl start minio' start_minio")
      expect { nx.start_minio }.to nap(1)
    end

    it "naps if the start is in progress" do
      expect(nx.vm.sshable).to receive(:_cmd).with("common/bin/daemonizer --check start_minio").and_return("InProgress")
      expect { nx.start_minio }.to nap(1)
    end
  end

  describe "#wait_online" do
    before { minio_server.incr_initial_provisioning }

    it "naps if the server is offline" do
      stub_info([{state: "offline", endpoint: "1.2.3.4:9000"}])
      expect { nx.wait_online }.to nap(10)
      expect(minio_server.initial_provisioning_set?).to be true
    end

    it "naps if a drive does not have a format" do
      stub_info([{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "unformatted"}]}])
      expect { nx.wait_online }.to nap(10)
      expect(minio_server.initial_provisioning_set?).to be true
    end

    it "clears initial_provisioning and exits if the server is online" do
      stub_info([{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok", healing: true}]}])
      expect { nx.wait_online }.to exit({"msg" => "minio server vm is recreated"})
      expect(minio_server.initial_provisioning_set?(cached: false)).to be false
    end
  end
end
