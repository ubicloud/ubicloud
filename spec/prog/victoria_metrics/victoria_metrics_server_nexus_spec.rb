# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::VictoriaMetrics::VictoriaMetricsServerNexus do
  subject(:nx) {
    allow(Config).to receive(:victoria_metrics_service_project_id).and_return(project.id)
    described_class.new(Strand.new(id: "e29d876b-9437-4ba3-9949-99075ad8767d", prog: "VictoriaMetrics::VictoriaMetricsServerNexus", label: "start"))
  }

  let(:project) { Project.create_with_id(name: "default") }

  let(:vm) {
    instance_double(Vm,
      id: "vm-id",
      sshable: instance_double(Sshable),
      ephemeral_net4: "1.1.1.1",
      ephemeral_net6: IPAddr.new("2001:db8::1"),
      strand: instance_double(Strand, label: "wait"))
  }

  let(:victoria_metrics_resource) {
    VictoriaMetricsResource.create_with_id(
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-vm",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      root_cert_1: "root_cert_1",
      root_cert_key_1: "root_cert_key_1",
      root_cert_2: "root_cert_2",
      root_cert_key_2: "root_cert_key_2",
      admin_user: "vm-admin",
      admin_password: "dummy-password",
      project_id: project.id
    )
  }

  let(:victoria_metrics_server) {
    instance_double(
      VictoriaMetricsServer,
      id: "test-id",
      vm: vm,
      resource: victoria_metrics_resource,
      cert: "cert",
      cert_key: "cert_key",
      certificate_last_checked_at: Time.now
    )
  }

  before do
    allow(nx).to receive(:victoria_metrics_server).and_return(victoria_metrics_server)
  end

  describe ".assemble" do
    it "creates a victoria metrics server" do
      allow(Config).to receive(:victoria_metrics_service_project_id).and_return(project.id)
      st = described_class.assemble(victoria_metrics_resource.id)
      expect(VictoriaMetricsServer.count).to eq 1
      expect(st.label).to eq "start"
      expect(VictoriaMetricsServer.first.resource).to eq victoria_metrics_resource
    end

    it "fails if resource is not valid" do
      expect {
        described_class.assemble(SecureRandom.uuid)
      }.to raise_error RuntimeError, "No existing VictoriaMetricsResource"
    end
  end

  describe "#start" do
    it "naps if vm is not ready" do
      allow(victoria_metrics_server.vm.strand).to receive(:label).and_return("start")
      expect { nx.start }.to nap(5)
    end

    it "creates certificate and hops to bootstrap_rhizome if vm is ready" do
      expect(victoria_metrics_server).to receive(:incr_initial_provisioning)
      expect(nx).to receive(:register_deadline).with("wait", 10 * 60)
      expect(nx).to receive(:create_certificate).and_return(["cert", "key"])
      expect(victoria_metrics_server).to receive(:update).with(cert: "cert", cert_key: "key")
      expect { nx.start }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds bootstrap rhizome and hops" do
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "victoria_metrics", "subject_id" => victoria_metrics_server.vm.id, "user" => "ubi"})
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "hops to create_victoria_metrics_user if bootstrap is complete" do
      expect(nx).to receive(:leaf?).and_return(true)
      expect { nx.wait_bootstrap_rhizome }.to hop("create_victoria_metrics_user")
    end

    it "donates if bootstrap is not complete" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_bootstrap_rhizome }.to nap(1)
    end
  end

  describe "#create_victoria_metrics_user" do
    it "creates victoria_metrics user and hops to install" do
      expect(vm.sshable).to receive(:cmd).with("sudo groupadd -f --system victoria_metrics")
      expect(vm.sshable).to receive(:cmd).with("sudo useradd --no-create-home --system -g victoria_metrics victoria_metrics")
      expect { nx.create_victoria_metrics_user }.to hop("install")
    end

    it "handles case where user already exists" do
      expect(vm.sshable).to receive(:cmd).with("sudo groupadd -f --system victoria_metrics").and_raise(RuntimeError.new("already exists"))
      expect { nx.create_victoria_metrics_user }.to hop("install")
    end

    it "raises any other error than already exists" do
      expect(vm.sshable).to receive(:cmd).with("sudo groupadd -f --system victoria_metrics").and_raise(RuntimeError.new("some other error"))
      expect { nx.create_victoria_metrics_user }.to raise_error(RuntimeError, "some other error")
    end
  end

  describe "#install" do
    it "starts install and naps if not started" do
      expect(vm.sshable).to receive(:d_check).with("install_victoria_metrics").and_return("NotStarted")
      expect(vm.sshable).to receive(:d_run).with("install_victoria_metrics", "/home/ubi/victoria_metrics/bin/install", Config.victoria_metrics_version)
      expect { nx.install }.to nap(5)
    end

    it "hops to configure if install is complete" do
      expect(vm.sshable).to receive(:d_check).with("install_victoria_metrics").and_return("Succeeded")
      expect(vm.sshable).to receive(:d_clean).with("install_victoria_metrics")
      expect { nx.install }.to hop("configure")
    end

    it "naps if the status is unknown" do
      expect(victoria_metrics_server.vm.sshable).to receive(:d_check).with("install_victoria_metrics").and_return("Unknown")
      expect { nx.install }.to nap(5)
    end
  end

  describe "#mount_data_disk" do
    let(:volume) { instance_double(VmStorageVolume, device_path: "/dev/sdb") }
    let(:volumes_dataset) { instance_double(Sequel::Dataset) }

    before do
      allow(vm).to receive(:vm_storage_volumes_dataset).and_return(volumes_dataset)
      allow(volumes_dataset).to receive(:order_by).with(:disk_index).and_return(volumes_dataset)
      allow(volumes_dataset).to receive(:where).with(Sequel[:vm_storage_volume][:boot] => false).and_return(volumes_dataset)
      allow(volumes_dataset).to receive(:first).and_return(volume)
      allow(volume).to receive(:device_path).and_return("/dev/sdb")
    end

    it "starts mount_data_disk and naps if not started" do
      expect(vm.sshable).to receive(:d_check).with("format_victoria_metrics_disk").and_return("NotStarted")
      expect(vm.sshable).to receive(:d_run).with("format_victoria_metrics_disk", "mkfs.ext4", "/dev/sdb")
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "mounts the disk and hops to configure if mount_data_disk is complete" do
      expect(vm.sshable).to receive(:d_check).with("format_victoria_metrics_disk").and_return("Succeeded")
      expect(vm.sshable).to receive(:cmd).with("sudo mkdir -p /dat/victoria_metrics")
      expect(vm.sshable).to receive(:cmd).with("sudo common/bin/add_to_fstab /dev/sdb /dat/victoria_metrics ext4 defaults 0 0")
      expect(vm.sshable).to receive(:cmd).with("sudo mount /dev/sdb /dat/victoria_metrics")
      expect(vm.sshable).to receive(:cmd).with("sudo chown -R victoria_metrics:victoria_metrics /dat/victoria_metrics")
      expect { nx.mount_data_disk }.to hop("configure")
    end

    it "naps if the status is unknown" do
      expect(vm.sshable).to receive(:d_check).with("format_victoria_metrics_disk").and_return("Unknown")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#configure" do
    it "starts configure and naps if not started" do
      expected_config = {
        admin_user: "vm-admin",
        admin_password: "dummy-password",
        cert: "cert",
        cert_key: "cert_key",
        ca_bundle: "root_cert_1\nroot_cert_2"
      }.to_json
      expect(vm.sshable).to receive(:d_check).with("configure_victoria_metrics").and_return("NotStarted")
      expect(vm.sshable).to receive(:d_run).with("configure_victoria_metrics", "/home/ubi/victoria_metrics/bin/configure", stdin: expected_config)
      expect { nx.configure }.to nap(5)
    end

    it "hops to wait if configure is complete" do
      expect(vm.sshable).to receive(:d_check).with("configure_victoria_metrics").and_return("Succeeded")
      expect(vm.sshable).to receive(:d_clean).with("configure_victoria_metrics")
      expect { nx.configure }.to hop("wait")
    end

    it "naps if the status is unknown" do
      expect(vm.sshable).to receive(:d_check).with("configure_victoria_metrics").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#wait" do
    it "handles reconfigure" do
      expect(nx).to receive(:when_reconfigure_set?).and_yield
      expect { nx.wait }.to hop("configure")
    end

    it "handles restart" do
      expect(nx).to receive(:when_restart_set?).and_yield
      expect(nx).to receive(:push).with(described_class, {}, "restart").and_call_original
      expect { nx.wait }.to hop("restart")
    end

    it "hops to refresh_certificates if certificate is old" do
      expect(victoria_metrics_server).to receive(:certificate_last_checked_at).and_return(Time.now - 60 * 60 * 24 * 31)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "naps if no action needed" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
    end
  end

  describe "#refresh_certificates" do
    it "creates new certificates and triggers reconfigure" do
      expect(nx).to receive(:create_certificate).and_return(["new_cert", "new_key"])
      expect(victoria_metrics_server).to receive(:update).with(cert: "new_cert", cert_key: "new_key", certificate_last_checked_at: anything)
      expect(nx).to receive(:incr_reconfigure)
      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#restart" do
    it "pops if restart succeeded" do
      expect(victoria_metrics_server.vm.sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("Succeeded")
      expect(victoria_metrics_server.vm.sshable).to receive(:d_clean).with("restart_victoria_metrics")
      expect { nx.restart }.to exit({"msg" => "victoria_metrics server is restarted"})
    end

    it "starts restart and naps if failed" do
      expect(victoria_metrics_server.vm.sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("Failed")
      expect(victoria_metrics_server.vm.sshable).to receive(:d_run).with("restart_victoria_metrics", "/home/ubi/victoria_metrics/bin/restart")
      expect { nx.restart }.to nap(1)
    end

    it "naps if restart is not started" do
      expect(victoria_metrics_server.vm.sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("NotStarted")
      expect(victoria_metrics_server.vm.sshable).to receive(:d_run).with("restart_victoria_metrics", "/home/ubi/victoria_metrics/bin/restart")
      expect { nx.restart }.to nap(1)
    end

    it "naps if status is unknown" do
      expect(victoria_metrics_server.vm.sshable).to receive(:d_check).with("restart_victoria_metrics").and_return("Unknown")
      expect { nx.restart }.to nap(1)
    end
  end

  describe "#destroy" do
    it "destroys the victoria metrics server" do
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(nx.strand).to receive(:children).and_return([])
      expect(victoria_metrics_server.vm).to receive(:incr_destroy)
      expect(victoria_metrics_server).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "victoria_metrics server destroyed"})
    end
  end

  describe "#before_run" do
    it "hops to destroy if destroy is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).at_least(:once).and_return("start")
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "pops if destroy is set and stack has items" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect(nx.strand.stack).to receive(:count).and_return(2)
      expect { nx.before_run }.to exit({"msg" => "operation is cancelled due to the destruction of the VictoriaMetrics server"})
    end
  end

  describe "#create_certificate" do
    # rubocop:disable RSpec/IndexedLet
    let(:root_cert_1) { instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 5) }
    let(:root_cert_key_1) { instance_double(OpenSSL::PKey::EC) }
    let(:root_cert_2) { instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 10) }
    let(:root_cert_key_2) { instance_double(OpenSSL::PKey::EC) }
    # rubocop:enable RSpec/IndexedLet
    let(:cert) { instance_double(OpenSSL::X509::Certificate, to_pem: "cert") }
    let(:key) { instance_double(OpenSSL::PKey::EC, to_pem: "key") }

    before do
      allow(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_1").and_return(root_cert_1)
      allow(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_1").and_return(root_cert_key_1)
      allow(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_2").and_return(root_cert_2)
      allow(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_2").and_return(root_cert_key_2)
    end

    it "uses root cert 1 if not close to expiry" do
      expect(Util).to receive(:create_certificate).with(
        subject: "/C=US/O=Ubicloud/CN=#{victoria_metrics_server.resource.ubid} Server Certificate",
        extensions: ["subjectAltName=DNS:#{victoria_metrics_server.resource.hostname},DNS:#{victoria_metrics_server.resource.hostname}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
        duration: 60 * 60 * 24 * 30 * 6,
        issuer_cert: root_cert_1,
        issuer_key: root_cert_key_1
      ).and_return([cert, key])
      expect(nx.create_certificate).to eq(["cert", "key"])
    end

    it "uses root cert 2 if root cert 1 is close to expiry" do
      allow(root_cert_1).to receive(:not_after).and_return(Time.now + 60 * 60 * 24 * 364)
      expect(Util).to receive(:create_certificate).with(
        subject: "/C=US/O=Ubicloud/CN=#{victoria_metrics_server.resource.ubid} Server Certificate",
        extensions: ["subjectAltName=DNS:#{victoria_metrics_server.resource.hostname},DNS:#{victoria_metrics_server.resource.hostname}", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
        duration: 60 * 60 * 24 * 30 * 6,
        issuer_cert: root_cert_2,
        issuer_key: root_cert_key_2
      ).and_return([cert, key])
      expect(nx.create_certificate).to eq(["cert", "key"])
    end

    it "adds IP SAN if running in development or E2E environment" do
      allow(Config).to receive(:development?).and_return(true)
      expect(victoria_metrics_server.vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      expect(victoria_metrics_server.vm).to receive(:ephemeral_net6).and_return(NetAddr::IPv6Net.parse("2a01:4f8:10a:128b:814c::/79"))

      expect(Util).to receive(:create_certificate).with(
        subject: "/C=US/O=Ubicloud/CN=#{victoria_metrics_server.resource.ubid} Server Certificate",
        extensions: ["subjectAltName=DNS:#{victoria_metrics_server.resource.hostname},DNS:#{victoria_metrics_server.resource.hostname},IP:1.1.1.1,IP:2a01:4f8:10a:128b:814c::2", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
        duration: 60 * 60 * 24 * 30 * 6,
        issuer_cert: root_cert_1,
        issuer_key: root_cert_key_1
      ).and_return([cert, key])

      expect(nx.create_certificate).to eq(["cert", "key"])
    end
  end
end
