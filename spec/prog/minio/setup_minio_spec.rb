# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::SetupMinio do
  subject(:nx) { described_class.new(Strand.new) }

  let(:minio_server) {
    prj = Project.create_with_id(name: "default", provider: "hetzner")
    prj.associate_with_project(prj)
    ps = Prog::Vnet::SubnetNexus.assemble(
      prj.id, name: "minio-cluster-name"
    )

    mc = MinioCluster.create_with_id(
      location: "hetzner-hel1",
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      target_total_storage_size_gib: 100,
      target_total_pool_count: 1,
      target_total_server_count: 1,
      target_total_drive_count: 1,
      target_vm_size: "standard-2",
      private_subnet_id: ps.id
    )

    mp = MinioPool.create_with_id(
      start_index: 0,
      cluster_id: mc.id
    )
    vm = Vm.create_with_id(unix_user: "u", public_key: "k", name: "n", location: "l", boot_image: "i", family: "f", cores: 2)
    MinioServer.create_with_id(
      minio_pool_id: mp.id,
      vm_id: vm.id,
      index: 0
    )
  }

  before do
    nx.instance_variable_set(:@minio_server, minio_server)
    sshable = instance_double(Sshable, host: "host")
    allow(minio_server.vm).to receive(:sshable).and_return(sshable)
  end

  describe ".install_minio" do
    it "pops if minio is installed" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check install_minio").and_return("Succeeded")
      expect { nx.install_minio }.to exit({"msg" => "minio is installed"})
    end

    it "installs minio if failed" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check install_minio").and_return("Failed")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'minio/bin/install_minio minio_20231007150738.0.0_amd64' install_minio")
      expect { nx.install_minio }.to nap(5)
    end

    it "naps if check returns unknown" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check install_minio").and_return("Unknown")
      expect { nx.install_minio }.to nap(5)
    end

    it "installs minio if NotStarted" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check install_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'minio/bin/install_minio minio_20231007150738.0.0_amd64' install_minio")
      expect { nx.install_minio }.to nap(5)
    end
  end

  describe ".configure_minio" do
    let(:config) {
      minio_config = <<ECHO
MINIO_VOLUMES="/minio/dat1"
MINIO_OPTS="--console-address :9001"
MINIO_ROOT_USER="minio-admin"
MINIO_ROOT_PASSWORD="dummy-password"
ECHO
      minio_hosts = <<ECHO
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
192.168.0.0 minio-cluster-name0.minio.ubicloud.com
ECHO
      JSON.generate({
        minio_config: minio_config,
        hosts: minio_hosts
      }).chomp
    }

    it "configures minio if not started" do
      expect(nx.minio_server.cluster.servers.first).to receive(:private_ipv4_address).and_return("192.168.0.0")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config)

      expect { nx.configure_minio }.to nap(5)
    end

    it "pops if minio is configured" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_minio").and_return("Succeeded")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_minio")
      expect { nx.configure_minio }.to exit({"msg" => "minio is configured"})
    end

    it "configures minio if failed" do
      expect(nx.minio_server.cluster.servers.first).to receive(:private_ipv4_address).and_return("192.168.0.0")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_minio").and_return("Failed")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config)

      expect { nx.configure_minio }.to nap(5)
    end

    it "naps if check returns unknown" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_minio").and_return("Unknown")
      expect { nx.configure_minio }.to nap(5)
    end
  end

  describe ".mount_data_disks" do
    it "mounts data disks" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disks").and_return("Succeeded")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo mkdir -p /minio")
      expect(nx.minio_server.vm).to receive_message_chain(:vm_storage_volumes_dataset, :order_by, :where, :all).and_return([instance_double(VmStorageVolume, boot: false, device_path: "/dev/dummy")]) # rubocop:disable RSpec/MessageChain
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo mkdir -p /minio/dat1")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo common/bin/add_to_fstab /dev/dummy /minio/dat1 xfs defaults 0 0")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo mount /dev/dummy /minio/dat1")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo chown -R minio-user:minio-user /minio")
      expect { nx.mount_data_disks }.to exit({"msg" => "data disks are mounted"})
    end

    it "formats data disks" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disks").and_return("Failed")
      expect(nx.minio_server.vm).to receive_message_chain(:vm_storage_volumes_dataset, :order_by, :where, :all).and_return([instance_double(VmStorageVolume, boot: false, device_path: "/dev/dummy")]) # rubocop:disable RSpec/MessageChain
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo mkfs --type xfs /dev/dummy' format_disks")
      expect { nx.mount_data_disks }.to nap(5)
    end

    it "naps if check returns unknown" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disks").and_return("Unknown")
      expect { nx.mount_data_disks }.to nap(5)
    end
  end
end
