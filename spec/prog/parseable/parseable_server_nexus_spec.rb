# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Parseable::ParseableServerNexus do
  subject(:nx) { described_class.new(st) }

  let(:parseable_project) { Project.create(name: "parseable-svc") }
  let(:sshable) { nx.vm.sshable }
  let(:st) { described_class.assemble(parseable_resource) }

  let(:parseable_resource) {
    ps_st = Prog::Vnet::SubnetNexus.assemble(parseable_project.id, name: "test-parseable-subnet", location_id: Location::HETZNER_FSN1_ID)
    pr = ParseableResource.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-parseable",
      admin_user: "admin",
      admin_password: "dummy-password",
      root_cert_1: root_cert_pem,
      root_cert_key_1: root_cert_key_pem,
      root_cert_2: root_cert_pem,
      root_cert_key_2: root_cert_key_pem,
      access_key: "access-key-1234",
      secret_key: "secret-key-5678",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100,
      project_id: parseable_project.id,
      private_subnet_id: ps_st.id,
    )
    Strand.create_with_id(pr, prog: "Parseable::ParseableResourceNexus", label: "wait")
    pr
  }

  let(:parseable_server) { nx.parseable_server }

  let(:root_cert) { Util.create_root_certificate(common_name: "test", duration: 60 * 60 * 24 * 365) }
  let(:root_cert_pem) { root_cert[0] }
  let(:root_cert_key_pem) { root_cert[1] }

  let(:dns_zone) { DnsZone.create(project_id: parseable_project.id, name: "parseable.example.com") }

  let(:blob_storage) {
    MinioCluster.create(
      name: "test-minio",
      admin_user: "admin",
      admin_password: "password",
      project_id: parseable_project.id,
      location_id: Location::HETZNER_FSN1_ID,
      root_cert_1: "cert1",
      root_cert_2: "cert2",
    )
  }

  before do
    allow(Config).to receive_messages(parseable_service_project_id: parseable_project.id, parseable_host_name: "parseable.example.com", parseable_version: "v2.6.3", postgres_service_project_id: parseable_project.id)
    add_ipv4_to_vm(nx.vm, "1.2.3.4")
    nx.vm.update(ephemeral_net6: "2a01::/64")
  end

  describe "#start" do
    it "naps if vm strand is not yet waiting" do
      nx.vm.strand.update(label: "start")
      expect { nx.start }.to nap(5)
    end

    it "hops to bootstrap_rhizome when vm is ready" do
      nx.vm.strand.update(label: "wait")
      expect { nx.start }.to hop("bootstrap_rhizome")
    end

    it "inserts A and AAAA DNS records when a dns_zone is present" do
      nx.vm.strand.update(label: "wait")

      dns_zone
      expect { nx.start }.to hop("bootstrap_rhizome")

      expect(dns_zone.records_dataset.where(type: "A", data: "1.2.3.4", tombstoned: false).count).to eq(1)
      expect(dns_zone.records_dataset.where(type: "AAAA", data: "2a01::2", tombstoned: false).count).to eq(1)
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds BootstrapRhizome and hops to wait_bootstrap_rhizome" do
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")

      expect(nx.strand.children.count).to eq(1)
      bootstrap_rhizome_st = nx.strand.children.first
      frame = bootstrap_rhizome_st.stack.first
      expect(bootstrap_rhizome_st.prog).to eq("BootstrapRhizome")
      expect(frame).to eq({"target_folder" => "parseable", "subject_id" => parseable_server.vm.id, "user" => "ubi"})
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "reaps and hops to create_parseable_user when done" do
      expect(nx).to receive(:reap).with(:create_parseable_user)
      nx.wait_bootstrap_rhizome
    end
  end

  describe "#create_parseable_user" do
    it "creates the parseable system user and hops to install" do
      expect(sshable).to receive(:_cmd).with("sudo groupadd -f --system parseable")
      expect(sshable).to receive(:_cmd).with("sudo useradd --no-create-home --system -g parseable parseable")
      expect { nx.create_parseable_user }.to hop("install")
    end

    it "ignores already-exists errors" do
      expect(sshable).to receive(:_cmd).with("sudo groupadd -f --system parseable")
      expect(sshable).to receive(:_cmd).with("sudo useradd --no-create-home --system -g parseable parseable").and_raise("useradd: user 'parseable' already exists")
      expect { nx.create_parseable_user }.to hop("install")
    end

    it "re-raises unexpected errors" do
      expect(sshable).to receive(:_cmd).with("sudo groupadd -f --system parseable").and_raise("permission denied")
      expect { nx.create_parseable_user }.to raise_error("permission denied")
    end
  end

  describe "#install" do
    it "starts install when NotStarted" do
      expect(sshable).to receive(:d_check).with("install_parseable").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("install_parseable", "/home/ubi/parseable/bin/install", Config.parseable_version)
      expect { nx.install }.to nap(5)
    end

    it "naps while install is in progress" do
      expect(sshable).to receive(:d_check).with("install_parseable").and_return("InProgress")
      expect { nx.install }.to nap(5)
    end

    it "hops to mount_data_disk when install succeeds" do
      expect(sshable).to receive(:d_check).with("install_parseable").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("install_parseable")
      expect { nx.install }.to hop("mount_data_disk")
    end

    it "restarts install on failure" do
      expect(sshable).to receive(:d_check).with("install_parseable").and_return("Failed")
      expect(sshable).to receive(:d_run).with("install_parseable", "/home/ubi/parseable/bin/install", Config.parseable_version)
      expect { nx.install }.to nap(5)
    end
  end

  describe "#mount_data_disk" do
    let(:path) {
      volume = nx.vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).first
      volume.device_path
    }

    it "starts format when NotStarted" do
      expect(sshable).to receive(:d_check).with("format_parseable_disk").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("format_parseable_disk", "mkfs.ext4", path)
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "mounts and hops to configure when format succeeds" do
      expect(sshable).to receive(:d_check).with("format_parseable_disk").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /dat/parseable")
      expect(sshable).to receive(:_cmd).with("sudo common/bin/add_to_fstab #{path} /dat/parseable ext4 defaults 0 0")
      expect(sshable).to receive(:_cmd).with("sudo mount #{path} /dat/parseable")
      expect(sshable).to receive(:_cmd).with("sudo chown -R parseable:parseable /dat/parseable")
      expect { nx.mount_data_disk }.to hop("configure")
    end

    it "naps when format is in progress" do
      expect(sshable).to receive(:d_check).with("format_parseable_disk").and_return("InProgress")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#configure" do
    it "runs configure_parseable when NotStarted" do
      blob_storage
      expected_config = {
        admin_user: parseable_resource.admin_user,
        admin_password: parseable_resource.admin_password,
        cert: st.subject.cert,
        cert_key: st.subject.cert_key,
        ca_bundle: parseable_resource.root_certs,
        s3_url: parseable_resource.blob_storage_endpoint,
        s3_bucket: parseable_resource.bucket_name,
        s3_access_key: parseable_resource.access_key,
        s3_secret_key: parseable_resource.secret_key,
        s3_ca_bundle: parseable_resource.blob_storage.root_certs,
      }.to_json

      expect(sshable).to receive(:d_check).with("configure_parseable").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("configure_parseable", "/home/ubi/parseable/bin/configure", stdin: expected_config)
      expect { nx.configure }.to nap(5)
    end

    it "naps while configure_parseable is InProgress" do
      expect(sshable).to receive(:d_check).with("configure_parseable").and_return("InProgress")
      expect { nx.configure }.to nap(5)
    end

    it "hops to wait after configure_parseable succeeds" do
      expect(sshable).to receive(:d_check).with("configure_parseable").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("configure_parseable")
      expect { nx.configure }.to hop("wait")
    end
  end

  describe "#wait" do
    before { st.update(label: "wait") }

    it "naps for approximately one month" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
    end

    it "hops to unavailable if checkup fails" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end

    it "decrements checkup if server is available" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
      expect(Semaphore.where(strand_id: nx.strand.id, name: "checkup").count).to eq(0)
    end

    it "hops to configure on reconfigure" do
      nx.incr_reconfigure
      expect { nx.wait }.to hop("configure")
    end

    it "hops to refresh_certificates when cert is old" do
      parseable_server.certificate_last_checked_at = Time.now - 60 * 60 * 24 * 31
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "calls daemonized_restart and naps when restart semaphore is set but restart not yet done" do
      nx.incr_restart
      expect(nx).to receive(:clear_restart_state)
      expect(nx).to receive(:daemonized_restart).and_return(false)
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
      expect(Semaphore.where(strand_id: nx.strand.id, name: "restart").count).to eq(0)
    end

    it "hops to wait after daemonized_restart completes" do
      expect(nx).to receive(:when_restart_set?).and_yield
      expect(nx).to receive(:decr_restart)
      expect(nx).to receive(:clear_restart_state)
      expect(nx).to receive(:daemonized_restart).and_return(true)
      expect { nx.wait }.to hop("wait")
    end
  end

  describe "#refresh_certificates" do
    it "creates new cert, updates server, increments reconfigure, and hops to wait" do
      expect(nx).to receive(:create_certificate).and_return(["new_cert", "new_key"])
      expect(nx.parseable_server).to receive(:update).with(cert: "new_cert", cert_key: "new_key", certificate_last_checked_at: anything)
      expect(nx).to receive(:incr_reconfigure)
      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#unavailable" do
    it "hops to wait if server becomes available" do
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:clear_restart_state)
      expect { nx.unavailable }.to hop("wait")
    end

    it "calls daemonized_restart and naps when server is still down" do
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:daemonized_restart)
      expect { nx.unavailable }.to nap(5)
    end
  end

  describe "#clear_restart_state" do
    it "cleans up when restart state is Succeeded" do
      expect(sshable).to receive(:d_check).with("restart_parseable").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("restart_parseable")
      nx.clear_restart_state
    end

    it "does nothing when restart state is not Succeeded" do
      expect(sshable).to receive(:d_check).with("restart_parseable").and_return("NotStarted")
      expect(sshable).not_to receive(:d_clean)
      nx.clear_restart_state
    end
  end

  describe "#daemonized_restart" do
    it "runs restart_parseable when NotStarted" do
      expect(sshable).to receive(:d_check).with("restart_parseable").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("restart_parseable", "/home/ubi/parseable/bin/restart")
      expect(nx.daemonized_restart).to be false
    end

    it "returns false when restart_parseable is InProgress" do
      expect(sshable).to receive(:d_check).with("restart_parseable").and_return("InProgress")
      expect(nx.daemonized_restart).to be false
    end

    it "returns true and cleans up when restart succeeds" do
      expect(sshable).to receive(:d_check).with("restart_parseable").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("restart_parseable")
      expect(nx.daemonized_restart).to be true
    end
  end

  describe "#create_certificate" do
    before do
      root_cert_1, root_cert_key_1 = Util.create_root_certificate(common_name: "#{parseable_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
      root_cert_2, root_cert_key_2 = Util.create_root_certificate(common_name: "#{parseable_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)

      parseable_resource.update(root_cert_1:, root_cert_key_1:, root_cert_2:, root_cert_key_2:)
    end

    it "creates a certificate using root_cert_1 when root_cert_1 valid for more than 1 year" do
      cert_pem, _ = nx.create_certificate
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      expect(cert.verify(OpenSSL::X509::Certificate.new(parseable_resource.root_cert_1).public_key)).to be true
    end

    it "creates a certificate using root_cert_2 when root_cert_1 is valid for less than a year" do
      short_lived_cert_1, short_lived_key_1 = Util.create_root_certificate(common_name: "#{parseable_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 1 - 10)
      parseable_resource.update(root_cert_1: short_lived_cert_1, root_cert_key_1: short_lived_key_1)

      cert_pem, _ = nx.create_certificate
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      expect(cert.verify(OpenSSL::X509::Certificate.new(parseable_resource.root_cert_2).public_key)).to be true
    end

    it "includes an IP SAN in development and E2E" do
      expect(Config).to receive(:development?).and_return(true)

      cert_pem, _ = nx.create_certificate
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      san = cert.extensions.find { |e| e.oid == "subjectAltName" }.value
      expect(san).to include("IP Address:1.2.3.4")
      expect(san).to include("IP Address:2A01:0:0:0:0:0:0:2")
    end
  end

  describe "#destroy" do
    it "hops to_wait_children_destoyed" do
      st = Strand.create(prog: "Prog::BootstrapRhizome", label: "start", parent_id: nx.strand.id)
      expect { nx.destroy }.to hop("wait_children_destroyed")
      expect(Semaphore.where(name: "destroy").select_order_map(:strand_id)).to eq [st.id]
    end

    it "deletes the DNS record when a dns_zone is present" do
      dns_zone
      parseable_resource.dns_zone.insert_record(record_name: parseable_resource.hostname, type: "A", ttl: 10, data: nx.vm.ip4_string)
      parseable_resource.dns_zone.insert_record(record_name: parseable_resource.hostname, type: "AAAA", ttl: 10, data: nx.vm.ip6_string)

      expect { nx.destroy }.to hop("wait_children_destroyed")

      expect(dns_zone.records_dataset.where(type: "A", data: "1.2.3.4", tombstoned: true).count).to eq(1)
      expect(dns_zone.records_dataset.where(type: "AAAA", data: "2a01::2", tombstoned: true).count).to eq(1)
    end
  end

  describe "#wait_children_destroyed" do
    it "destroys vm and parseable_server when all children are reaped" do
      expect { nx.wait_children_destroyed }.to exit({"msg" => "parseable server destroyed"})
    end

    it "naps while waiting for children" do
      Strand.create(prog: "Prog::BootstrapRhizome", label: "start", parent_id: nx.strand.id)
      expect { nx.wait_children_destroyed }.to nap(5)
    end
  end

  describe "#available?" do
    it "returns true during initial provisioning" do
      nx.incr_initial_provisioning
      expect(nx.available?).to be true
    end

    it "returns true when health check passes" do
      client = instance_double(Parseable::Client)
      expect(nx.parseable_server).to receive(:client).and_return(client)
      expect(client).to receive(:healthy?).and_return(true)
      expect(nx.available?).to be true
    end

    it "returns false and emits log when health check raises" do
      client = instance_double(Parseable::Client)
      expect(nx.parseable_server).to receive(:client).and_return(client)
      expect(client).to receive(:healthy?).and_raise("connection refused")
      expect(Clog).to receive(:emit).with("parseable server is down", anything)
      expect(nx.available?).to be false
    end
  end
end
