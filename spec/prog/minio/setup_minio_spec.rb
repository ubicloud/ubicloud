# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::SetupMinio do
  subject(:nx) { described_class.new(Strand.new) }

  let(:minio_server) {
    prj = Project.create(name: "default")
    ps = Prog::Vnet::SubnetNexus.assemble(
      prj.id, name: "minio-cluster-name"
    )

    mc = MinioCluster.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      private_subnet_id: ps.id,
      root_cert_1: "root_cert_1",
      root_cert_key_1: "root_cert_key_1",
      root_cert_2: "root_cert_2",
      root_cert_key_2: "root_cert_key_2",
      project_id: prj.id
    )

    mp = MinioPool.create(
      start_index: 0,
      cluster_id: mc.id,
      vm_size: "standard-2",
      server_count: 1,
      drive_count: 1
    )
    MinioServer.create(
      minio_pool_id: mp.id,
      vm_id: create_vm.id,
      index: 0,
      cert: "cert",
      cert_key: "key"
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
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'minio/bin/install_minio minio_20240406052602.0.0_amd64' install_minio")
      expect { nx.install_minio }.to nap(5)
    end

    it "naps if check returns unknown" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check install_minio").and_return("Unknown")
      expect { nx.install_minio }.to nap(5)
    end

    it "installs minio if NotStarted" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check install_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'minio/bin/install_minio minio_20240406052602.0.0_amd64' install_minio")
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
MINIO_SERVER_URL="https://minio-cluster-name.minio.ubicloud.com:9000"
ECHO
      minio_hosts = <<ECHO
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
127.0.0.1 minio-cluster-name0.minio.ubicloud.com
ECHO
      JSON.generate({
        minio_config: minio_config,
        hosts: minio_hosts,
        cert: "cert",
        cert_key: "key",
        ca_bundle: "root_cert_1" + "root_cert_2"
      }).chomp
    }

    before do
      allow(DnsZone).to receive(:where).and_return([instance_double(DnsZone, name: "minio.ubicloud.com")])
    end

    it "configures minio if not started" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config)

      expect { nx.configure_minio }.to nap(5)
    end

    it "configures minio without server_url if dns is not configures" do
      expect(nx.minio_server.cluster).to receive(:dns_zone).and_return(false)
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config.gsub("MINIO_SERVER_URL=\\\"https://minio-cluster-name.minio.ubicloud.com:9000\\\"", ""))

      expect { nx.configure_minio }.to nap(5)
    end

    it "pops if minio is configured" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_minio").and_return("Succeeded")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_minio")
      expect { nx.configure_minio }.to exit({"msg" => "minio is configured"})
    end

    it "configures minio if failed" do
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
