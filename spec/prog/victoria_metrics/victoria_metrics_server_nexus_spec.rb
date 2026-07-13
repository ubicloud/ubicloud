# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::VictoriaMetrics::VictoriaMetricsServerNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "default") }
  let(:sshable) { nx.vm.sshable }

  let(:st) { described_class.assemble(victoria_metrics_resource.id) }

  let(:root_cert) { Util.create_root_certificate(common_name: "test", duration: 60 * 60 * 24 * 365 * 5) }
  let(:root_cert_pem) { root_cert[0] }
  let(:root_cert_key_pem) { root_cert[1] }

  let(:victoria_metrics_resource) {
    private_subnet_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-victoria-metrics-subnet", location_id: Location::HETZNER_FSN1_ID).id
    VictoriaMetricsResource.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-vm",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      root_cert_1: root_cert_pem,
      root_cert_key_1: root_cert_key_pem,
      root_cert_2: root_cert_pem,
      root_cert_key_2: root_cert_key_pem,
      admin_user: "vm-admin",
      admin_password: "dummy-password",
      project_id: project.id,
      private_subnet_id:,
    )
  }

  let(:victoria_metrics_server) { nx.victoria_metrics_server }

  before do
    allow(Config).to receive(:victoria_metrics_service_project_id).and_return(project.id)
  end

  describe ".assemble" do
    it "creates a representative victoria metrics server by default" do
      st = described_class.assemble(victoria_metrics_resource.id)
      expect(VictoriaMetricsServer.count).to eq 1
      expect(st.label).to eq "start"
      expect(VictoriaMetricsServer.first.resource).to eq victoria_metrics_resource
      expect(VictoriaMetricsServer.first.is_representative).to be true
    end

    it "creates a non-representative server when requested" do
      described_class.assemble(victoria_metrics_resource.id, is_representative: false)
      expect(VictoriaMetricsServer.first.is_representative).to be false
    end

    it "fails if resource is not valid" do
      expect {
        described_class.assemble(SecureRandom.uuid)
      }.to raise_error RuntimeError, "No existing VictoriaMetricsResource"
    end
  end

  describe "#start" do
    it "naps if vm is not ready" do
      expect { nx.start }.to nap(5)
    end

    it "creates certificate and hops to bootstrap_rhizome if vm is ready" do
      nx.vm.strand.update(label: "wait")

      expect { nx.start }.to hop("bootstrap_rhizome")

      victoria_metrics_server.reload
      expect(victoria_metrics_server.initial_provisioning_set?).to be true
      expect(victoria_metrics_server.cert).to be_a(String)
      expect(victoria_metrics_server.cert_key).to be_a(String)
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds bootstrap rhizome and hops" do
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")

      expect(nx.strand.children.count).to eq(1)
      child = nx.strand.children.first
      expect(child.prog).to eq("BootstrapRhizome")
      expect(child.stack.first).to eq({"target_folder" => "victoria_metrics", "subject_id" => nx.vm.id, "user" => "ubi"})
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to create_victoria_metrics_user if bootstrap is complete" do
      expect { nx.wait_bootstrap_rhizome }.to hop("create_victoria_metrics_user")
    end

    it "donates if bootstrap is not complete" do
      Strand.create(parent_id: nx.strand.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(120)
    end
  end

  describe "#create_victoria_metrics_user" do
    it "creates victoria_metrics user and hops to install" do
      expect(sshable).to receive(:_cmd).with("sudo groupadd -f --system victoria_metrics")
      expect(sshable).to receive(:_cmd).with("sudo useradd --no-create-home --system -g victoria_metrics victoria_metrics")
      expect { nx.create_victoria_metrics_user }.to hop("install")
    end

    it "handles case where user already exists" do
      expect(sshable).to receive(:_cmd).with("sudo groupadd -f --system victoria_metrics").and_raise(RuntimeError.new("already exists"))
      expect { nx.create_victoria_metrics_user }.to hop("install")
    end

    it "raises any other error than already exists" do
      expect(sshable).to receive(:_cmd).with("sudo groupadd -f --system victoria_metrics").and_raise(RuntimeError.new("some other error"))
      expect { nx.create_victoria_metrics_user }.to raise_error(RuntimeError, "some other error")
    end
  end

  describe "#install" do
    it "starts install and naps if not started" do
      expect(sshable).to receive(:d_check).with("install_victoria_metrics").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("install_victoria_metrics", "/home/ubi/victoria_metrics/bin/install", Config.victoria_metrics_version)
      expect { nx.install }.to nap(5)
    end

    it "hops to mount_data_disk if install is complete" do
      expect(sshable).to receive(:d_check).with("install_victoria_metrics").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("install_victoria_metrics")
      expect { nx.install }.to hop("mount_data_disk")
    end

    it "naps if the status is unknown" do
      expect(sshable).to receive(:d_check).with("install_victoria_metrics").and_return("Unknown")
      expect { nx.install }.to nap(5)
    end
  end

  describe "#mount_data_disk" do
    let(:path) {
      volume = nx.vm.vm_storage_volumes_dataset.order_by(:disk_index).where(Sequel[:vm_storage_volume][:boot] => false).first
      volume.device_path
    }

    it "starts mount_data_disk and naps if not started" do
      expect(sshable).to receive(:d_check).with("format_victoria_metrics_disk").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("format_victoria_metrics_disk", "mkfs.ext4", path)
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "mounts the disk and hops to configure if mount_data_disk is complete" do
      expect(sshable).to receive(:d_check).with("format_victoria_metrics_disk").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("sudo mkdir -p /dat/victoria_metrics")
      expect(sshable).to receive(:_cmd).with("sudo common/bin/add_to_fstab #{path} /dat/victoria_metrics ext4 defaults 0 0")
      expect(sshable).to receive(:_cmd).with("sudo mount #{path} /dat/victoria_metrics")
      expect(sshable).to receive(:_cmd).with("sudo chown -R victoria_metrics:victoria_metrics /dat/victoria_metrics")
      expect { nx.mount_data_disk }.to hop("configure")
    end

    it "naps if the status is unknown" do
      expect(sshable).to receive(:d_check).with("format_victoria_metrics_disk").and_return("Unknown")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#configure" do
    before do
      victoria_metrics_server.update(cert: "cert", cert_key: "cert_key")
    end

    it "starts configure and naps if not started" do
      expected_config = {
        admin_user: "vm-admin",
        admin_password: "dummy-password",
        cert: "cert",
        cert_key: "cert_key",
        ca_bundle: "#{root_cert_pem}\n#{root_cert_pem}",
      }.to_json
      expect(sshable).to receive(:d_check).with("configure_victoria_metrics").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("configure_victoria_metrics", "/home/ubi/victoria_metrics/bin/configure", stdin: expected_config)
      expect { nx.configure }.to nap(5)
    end

    it "hops to wait if configure is complete" do
      expect(sshable).to receive(:d_check).with("configure_victoria_metrics").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("configure_victoria_metrics")
      expect { nx.configure }.to hop("wait")
    end

    it "naps if the status is unknown" do
      expect(sshable).to receive(:d_check).with("configure_victoria_metrics").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#wait" do
    it "handles reconfigure" do
      nx.incr_reconfigure
      expect { nx.wait }.to hop("configure")
      expect(victoria_metrics_server.reload.reconfigure_set?).to be false
    end

    it "handles restart" do
      nx.incr_restart
      expect { nx.wait }.to hop("restart")
    end

    it "hops to refresh_certificates if certificate is old" do
      victoria_metrics_server.update(certificate_last_checked_at: Time.now - 60 * 60 * 24 * 31)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "handles checkup when server is unavailable" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end

    it "handles checkup when server is available" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
      expect(victoria_metrics_server.reload.checkup_set?).to be false
    end

    it "naps if no action needed" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
    end
  end

  describe "#refresh_certificates" do
    it "creates new certificates and triggers reconfigure" do
      old_cert = victoria_metrics_server.cert

      expect { nx.refresh_certificates }.to hop("wait")

      victoria_metrics_server.reload
      expect(victoria_metrics_server.cert).to be_a(String)
      expect(victoria_metrics_server.cert).not_to eq(old_cert)
      expect(victoria_metrics_server.certificate_last_checked_at).to be_within(5).of(Time.now)
      expect(victoria_metrics_server.reconfigure_set?).to be true
    end
  end

  describe "#restart" do
    it "pops if restart succeeded" do
      expect(sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("restart_victoria_metrics")
      expect { nx.restart }.to exit({"msg" => "victoria_metrics server is restarted"})
    end

    it "starts restart and naps if failed" do
      expect(sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("Failed")
      expect(sshable).to receive(:d_run).with("restart_victoria_metrics", "/home/ubi/victoria_metrics/bin/restart")
      expect { nx.restart }.to nap(1)
    end

    it "naps if restart is not started" do
      expect(sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("restart_victoria_metrics", "/home/ubi/victoria_metrics/bin/restart")
      expect { nx.restart }.to nap(1)
    end

    it "naps if status is unknown" do
      expect(sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("Unknown")
      expect { nx.restart }.to nap(1)
    end
  end

  describe "#destroy" do
    it "adds destroy semaphore to children and hops to wait_children_destroyed" do
      child = Strand.create(prog: "Prog::BootstrapRhizome", label: "start", parent_id: nx.strand.id, stack: [{}])
      expect { nx.destroy }.to hop("wait_children_destroyed")
      expect(Semaphore.where(name: "destroy").select_order_map(:strand_id)).to eq [child.id]
    end
  end

  describe "#wait_children_destroyed" do
    it "naps if children still exist" do
      Strand.create(prog: "Prog::BootstrapRhizome", label: "start", parent_id: nx.strand.id, stack: [{}])
      expect { nx.wait_children_destroyed }.to nap(5)
    end

    it "destroys the victoria metrics server" do
      vm_id = victoria_metrics_server.vm.id

      expect { nx.wait_children_destroyed }.to exit({"msg" => "victoria_metrics server destroyed"})

      expect(Vm[vm_id].destroy_set?).to be true
      expect(victoria_metrics_server).not_to exist
    end
  end

  describe "#before_run" do
    it "hops to destroy if destroy is set" do
      nx.incr_destroy
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in destroy state" do
      nx.incr_destroy
      nx.strand.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_children_destroyed state" do
      nx.incr_destroy
      nx.strand.update(label: "wait_children_destroyed")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "pops if in restart state and has a parent" do
      nx.incr_destroy
      nx.strand.update(label: "restart")
      nx.strand.parent_id = nx.strand.id
      expect { nx.before_run }.to exit({"msg" => "exiting early due to destroy semaphore"})
    end

    it "hops to destroy if in restart state and does not have a parent" do
      nx.incr_destroy
      nx.strand.update(label: "restart")
      expect { nx.before_run }.to hop("destroy")
    end

    it "pops if destroy is set and stack has items" do
      nx.incr_destroy
      nx.strand.update(label: "destroy")
      expect(nx.strand.stack).to receive(:count).and_return(2)
      expect { nx.before_run }.to exit({"msg" => "operation is cancelled due to the destruction of the VictoriaMetrics server"})
    end
  end

  describe "#create_certificate" do
    it "uses root cert 1 if not close to expiry" do
      cert_pem, _key_pem = nx.create_certificate
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      expect(cert.issuer.to_s).to eq(OpenSSL::X509::Certificate.new(root_cert_pem).subject.to_s)
    end

    it "uses root cert 2 if root cert 1 is close to expiry" do
      near_cert_pem, near_key_pem = Util.create_root_certificate(common_name: "expiring-root", duration: 60 * 60 * 24 * 300)
      far_cert_pem, far_key_pem = Util.create_root_certificate(common_name: "valid-root", duration: 60 * 60 * 24 * 365 * 10)
      victoria_metrics_server.resource.update(root_cert_1: near_cert_pem, root_cert_key_1: near_key_pem, root_cert_2: far_cert_pem, root_cert_key_2: far_key_pem)

      cert_pem, _key_pem = nx.create_certificate
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      expect(cert.issuer.to_s).to eq(OpenSSL::X509::Certificate.new(far_cert_pem).subject.to_s)
    end

    it "adds IP SAN if running in development or E2E environment" do
      allow(Config).to receive(:development?).and_return(true)
      add_ipv4_to_vm(nx.vm, "1.1.1.1")
      nx.vm.update(ephemeral_net6: "2a01:4f8:10a:128b:814c::/79")

      cert_pem, _key_pem = nx.create_certificate
      cert = OpenSSL::X509::Certificate.new(cert_pem)
      san = cert.extensions.find { it.oid == "subjectAltName" }.value
      expect(san).to include("IP Address:1.1.1.1")
      ip6_san = san.scan(/IP Address:([0-9A-Fa-f:]+)/).last.first
      expect(IPAddr.new(ip6_san)).to eq(IPAddr.new(nx.vm.ip6.to_s))
    end
  end

  describe "#unavailable" do
    it "registers deadline and naps if restart is in progress" do
      expect(nx).to receive(:reap)
      Strand.create(parent_id: nx.strand.id, prog: "VictoriaMetrics::VictoriaMetricsServerNexus", label: "restart", stack: [{}])
      expect { nx.unavailable }.to nap(5)
    end

    it "hops to wait if server becomes available" do
      expect(nx).to receive(:reap)
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.unavailable }.to hop("wait")
      expect(victoria_metrics_server.reload.checkup_set?).to be false
    end

    it "buds restart and naps if server remains unavailable" do
      expect(nx).to receive(:reap)
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(5)

      expect(nx.strand.children.count).to eq(1)
      child = nx.strand.children.first
      expect(child.prog).to eq("VictoriaMetrics::VictoriaMetricsServerNexus")
      expect(child.label).to eq("restart")
    end
  end

  describe "#available?" do
    it "returns true if initial provisioning is set" do
      victoria_metrics_server.incr_initial_provisioning
      expect(nx.available?).to be true
    end

    it "returns true if health check succeeds" do
      expect(victoria_metrics_server).to receive(:client).and_return(instance_double(VictoriaMetrics::Client, health: true))
      expect(nx.available?).to be true
    end

    it "returns false if health check fails" do
      expect(victoria_metrics_server).to receive(:client).and_return(instance_double(VictoriaMetrics::Client, health: false))
      expect(nx.available?).to be false
    end

    it "returns false and logs error if health check raises exception" do
      client = instance_double(VictoriaMetrics::Client)
      expect(client).to receive(:health).and_raise(StandardError.new("Connection failed"))
      expect(victoria_metrics_server).to receive(:client).and_return(client)
      expect(Clog).to receive(:emit).with("victoria_metrics server is down", instance_of(Hash)).and_call_original
      expect(nx.available?).to be false
    end
  end
end
