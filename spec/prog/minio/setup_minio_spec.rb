# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::SetupMinio do
  subject(:nx) { described_class.new(minio_server.strand) }

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

    vm = create_vm
    Sshable.create_with_id(vm)
    VmStorageVolume.create(vm:, boot: false, size_gib: 100, disk_index: 1)
    minio_server = MinioServer.create(
      pool: mp,
      vm:,
      index: 0,
      cert: "cert",
      cert_key: "key"
    )
    Strand.create_with_id(minio_server, prog: "Minio::SetupMinio", label: "install_minio")
    minio_server
  }

  let(:sshable) { nx.minio_server.vm.sshable }

  describe ".install_minio" do
    it "pops if minio is installed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check install_minio").and_return("Succeeded")
      expect { nx.install_minio }.to exit({"msg" => "minio is installed"})
    end

    it "installs minio if failed" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check install_minio").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer minio/bin/install_minio\\ minio_20250723155402.0.0_amd64 install_minio")
      expect { nx.install_minio }.to nap(5)
    end

    it "naps if check returns unknown" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check install_minio").and_return("Unknown")
      expect { nx.install_minio }.to nap(5)
    end

    it "installs minio if NotStarted" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check install_minio").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer minio/bin/install_minio\\ minio_20250723155402.0.0_amd64 install_minio")
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
MINIO_STORAGE_CLASS_STANDARD="EC:0"
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
        minio_config:,
        hosts: minio_hosts,
        cert: "cert",
        cert_key: "key",
        ca_bundle: "root_cert_1" + "root_cert_2"
      }).chomp
    }

    before do
      allow(Config).to receive(:minio_service_project_id).and_return(minio_server.cluster.project_id)
    end

    def create_dns_zone
      DnsZone.create(project_id: Config.minio_service_project_id, name: Config.minio_host_name, last_purged_at: Time.now)
    end

    it "configures minio if not started" do
      create_dns_zone
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check configure_minio").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config)

      expect { nx.configure_minio }.to nap(5)
    end

    it "configures minio without server_url if dns is not configures" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check configure_minio").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config.gsub("MINIO_SERVER_URL=\\\"https://minio-cluster-name.minio.ubicloud.com:9000\\\"", ""))

      expect { nx.configure_minio }.to nap(5)
    end

    it "pops if minio is configured" do
      create_dns_zone
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check configure_minio").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --clean configure_minio")
      expect { nx.configure_minio }.to exit({"msg" => "minio is configured"})
    end

    it "configures minio if failed" do
      create_dns_zone
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check configure_minio").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer 'sudo minio/bin/configure-minio' configure_minio", stdin: config)

      expect { nx.configure_minio }.to nap(5)
    end

    it "naps if check returns unknown" do
      create_dns_zone
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check configure_minio").and_return("Unknown")
      expect { nx.configure_minio }.to nap(5)
    end
  end

  describe ".mount_data_disks" do
    let(:data_volume) { minio_server.vm.vm_storage_volumes.find { !it.boot } }

    it "mounts data disks" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check format_disks").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /minio")
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /minio/dat1")
      expect(sshable).to receive(:_cmd).with("sudo common/bin/add_to_fstab #{data_volume.device_path} /minio/dat1 xfs defaults 0 0")
      expect(sshable).to receive(:_cmd).with("sudo mount #{data_volume.device_path} /minio/dat1")
      expect(sshable).to receive(:_cmd).with("sudo chown -R minio-user:minio-user /minio")
      expect { nx.mount_data_disks }.to exit({"msg" => "data disks are mounted"})
    end

    it "formats data disks" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check format_disks").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer sudo\\ mkfs\\ --type\\ xfs\\ #{data_volume.device_path} format_disks")
      expect { nx.mount_data_disks }.to nap(5)
    end

    it "naps if check returns unknown" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer --check format_disks").and_return("Unknown")
      expect { nx.mount_data_disks }.to nap(5)
    end
  end
end
