# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Minio::MinioServerNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { described_class.assemble(minio_pool.id, 0) }

  let(:minio_pool) {
    ps = Prog::Vnet::SubnetNexus.assemble(
      minio_project.id, name: "minio-cluster-name"
    )
    mc = MinioCluster.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      private_subnet_id: ps.id,
      project_id: minio_project.id,
      root_cert_1: "root_cert_1",
      root_cert_key_1: "root_cert_key_1",
      root_cert_2: "root_cert_2",
      root_cert_key_2: "root_cert_key_2"
    )

    MinioPool.create(
      start_index: 0,
      cluster_id: mc.id,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100,
      vm_size: "standard-2"
    )
  }

  let(:cert_1) {
    instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 5)
  }
  let(:key_1) { instance_double(OpenSSL::PKey::EC) }
  let(:create_certificate_payload) {
    {
      subject: "/C=US/O=Ubicloud/CN=#{nx.minio_server.cluster.ubid} Server Certificate",
      extensions: ["subjectAltName=DNS:minio-cluster-name.minio.ubicloud.com,DNS:minio-cluster-name0.minio.ubicloud.com", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"],
      duration: 60 * 60 * 24 * 30 * 6,
      issuer_cert: cert_1,
      issuer_key: key_1
    }
  }

  let(:minio_project) { Project.create(name: "default") }

  before do
    allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
  end

  describe ".cluster" do
    it "returns minio cluster" do
      expect(nx.cluster).to eq minio_pool.cluster
    end
  end

  describe ".assemble" do
    it "creates a vm and minio server" do
      st = described_class.assemble(minio_pool.id, 0)
      expect(MinioServer.count).to eq 1
      expect(st.label).to eq "start"
      expect(MinioServer.first.pool).to eq minio_pool
      expect(Vm.count).to eq 1
      expect(Vm.first.unix_user).to eq "ubi"
      expect(Vm.first.sshable.host).to eq "temp_#{Vm.first.id}"
      expect(Vm.first.private_subnets.first.id).to eq minio_pool.cluster.private_subnet_id

      expect(Vm.first.strand.stack[0]["storage_volumes"].length).to eq 2
      expect(Vm.first.strand.stack[0]["storage_volumes"][0]["encrypted"]).to be true
      expect(Vm.first.strand.stack[0]["storage_volumes"][0]["size_gib"]).to eq 30
      expect(Vm.first.strand.stack[0]["storage_volumes"][1]["encrypted"]).to be true
      expect(Vm.first.strand.stack[0]["storage_volumes"][1]["size_gib"]).to eq 100
    end

    it "fails if pool is not valid" do
      expect {
        described_class.assemble(SecureRandom.uuid, 0)
      }.to raise_error RuntimeError, "No existing pool"
    end
  end

  describe "#start" do
    it "nap 5 sec until VM is up and running" do
      expect { nx.start }.to nap(5)
    end

    it "creates server certificate and hops to bootstrap_rhizome if dnszone doesn't exist" do
      vm = nx.minio_server.vm
      vm.strand.update(label: "wait")
      expect(nx).to receive(:vm).and_return(vm)
      expect(nx).to receive(:register_deadline)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_1").and_return(cert_1)
      expect(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_1").and_return(key_1)
      expect(Util).to receive(:create_certificate).with(create_certificate_payload).and_return([instance_double(OpenSSL::X509::Certificate, to_pem: "cert"), instance_double(OpenSSL::PKey::EC, to_pem: "cert_key")])
      expect(nx.minio_server).to receive(:update).and_call_original

      expect { nx.start }.to hop("bootstrap_rhizome")

      expect(nx.minio_server.cert).to eq "cert"
      expect(nx.minio_server.cert_key).to eq "cert_key"
    end

    it "creates server certificate with ip_san and hops to bootstrap_rhizome if dnszone doesn't exist" do
      vm = nx.minio_server.vm
      vm.strand.update(label: "wait")
      expect(nx).to receive(:vm).and_return(vm)
      expect(nx).to receive(:register_deadline)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_1").and_return(cert_1)
      expect(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_1").and_return(key_1)

      expect(Config).to receive(:development?).and_return(true)
      expect(vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      create_certificate_payload[:extensions] = ["subjectAltName=DNS:minio-cluster-name.minio.ubicloud.com,DNS:minio-cluster-name0.minio.ubicloud.com,IP:1.1.1.1", "keyUsage=digitalSignature,keyEncipherment", "subjectKeyIdentifier=hash", "extendedKeyUsage=serverAuth"]
      expect(Util).to receive(:create_certificate).with(create_certificate_payload).and_return([instance_double(OpenSSL::X509::Certificate, to_pem: "cert"), instance_double(OpenSSL::PKey::EC, to_pem: "cert_key")])

      expect(nx.minio_server).to receive(:update).and_call_original

      expect { nx.start }.to hop("bootstrap_rhizome")

      expect(nx.minio_server.cert).to eq "cert"
      expect(nx.minio_server.cert_key).to eq "cert_key"
    end

    it "inserts dns record and hops to bootstrap_rhizome if dnszone exists" do
      dz = DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      expect(nx.minio_server.cluster).to receive(:dns_zone).and_return(dz).at_least(:once)
      vm = nx.minio_server.vm
      vm.strand.update(label: "wait")
      expect(vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      expect(nx).to receive(:vm).and_return(vm).at_least(:once)
      expect(nx.minio_server.cluster.dns_zone).to receive(:insert_record).with(record_name: nx.cluster.hostname, type: "A", ttl: 10, data: "1.1.1.1")
      expect(nx).to receive(:register_deadline)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_1").and_return(cert_1)
      expect(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_1").and_return(key_1)
      expect(Util).to receive(:create_certificate).with(create_certificate_payload).and_return([instance_double(OpenSSL::X509::Certificate, to_pem: "cert"), instance_double(OpenSSL::PKey::EC, to_pem: "cert_key")])
      expect(nx.minio_server).to receive(:update).and_call_original

      expect { nx.start }.to hop("bootstrap_rhizome")
      expect(nx.minio_server.cert).to eq "cert"
      expect(nx.minio_server.cert_key).to eq "cert_key"
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds bootstrap rhizome and hops to wait_bootstrap_rhizome" do
      vm = nx.minio_server.vm
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "minio", "subject_id" => vm.id, "user" => "ubi"})
      expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    it "donates if bootstrap rhizome continues" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_bootstrap_rhizome }.to nap(120)
    end

    it "hops to setup if bootstrap rhizome is done" do
      expect { nx.wait_bootstrap_rhizome }.to hop("create_minio_user")
    end
  end

  describe "#create_minio_user" do
    it "creates minio user and hops to setup" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo groupadd -f --system minio-user")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo useradd --no-create-home --system -g minio-user minio-user")
      expect { nx.create_minio_user }.to hop("setup")
    end

    it "does not raise an exception if the user already exists" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo groupadd -f --system minio-user")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo useradd --no-create-home --system -g minio-user minio-user").and_raise(RuntimeError, "useradd: user 'minio-user' already exists")
      expect { nx.create_minio_user }.to hop("setup")
    end

    it "raises an exception if the useradd command fails with a different error" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo groupadd -f --system minio-user")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("sudo useradd --no-create-home --system -g minio-user minio-user").and_raise(RuntimeError, "Error!")

      expect { nx.create_minio_user }.to raise_error(RuntimeError, "Error!")
    end
  end

  describe "#setup" do
    it "buds minio setup and hops to wait_setup" do
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :mount_data_disks)
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :install_minio)
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :configure_minio)
      expect { nx.setup }.to hop("wait_setup")
    end
  end

  describe "#wait_setup" do
    it "donates if setup continues" do
      Strand.create(parent_id: st.id, prog: "SetupMinio", label: "mount_data_disks", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_setup }.to nap(120)
    end

    it "hops to wait if setup is done" do
      expect { nx.wait_setup }.to hop("wait")
    end
  end

  describe "#minio_restart" do
    it "hops to wait if succeeded" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("Succeeded")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean restart_minio")
      expect { nx.minio_restart }.to exit({"msg" => "minio server is restarted"})
    end

    it "naps if minio is not started" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("NotStarted")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'systemctl restart minio' restart_minio")
      expect { nx.minio_restart }.to nap(1)
    end

    it "naps if minio is failed" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("Failed")
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'systemctl restart minio' restart_minio")
      expect { nx.minio_restart }.to nap(1)
    end

    it "naps if the status is unknown" do
      expect(nx.minio_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check restart_minio").and_return("Unknown")
      expect { nx.minio_restart }.to nap(1)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(10)
    end

    it "hops to unavailable if checkup is set and the server is not available" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end

    it "naps if checkup is set but the server is available" do
      expect(nx).to receive(:when_checkup_set?).and_yield
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait }.to nap(10)
    end

    it "hops to wait_reconfigure if reconfigure is set" do
      expect(nx).to receive(:when_reconfigure_set?).and_yield
      expect(nx).to receive(:bud).with(Prog::Minio::SetupMinio, {}, :configure_minio)
      expect { nx.wait }.to hop("wait_reconfigure")
    end

    it "pushes minio_restart if restart is set" do
      expect(nx).to receive(:when_restart_set?).and_yield
      expect(nx).to receive(:push).with(described_class, {}, "minio_restart").and_call_original
      expect { nx.wait }.to hop("minio_restart")
    end

    it "pushes minio_restart and decrements initial_provisioning if restart is set" do
      expect(nx).to receive(:when_restart_set?).and_yield
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(nx).to receive(:decr_initial_provisioning)
      expect(nx).to receive(:push).with(described_class, {}, "minio_restart").and_call_original
      expect { nx.wait }.to hop("minio_restart")
    end

    it "hops to refresh_certificates if certificate is checked more than a month ago" do
      expect(nx.minio_server).to receive(:certificate_last_checked_at).and_return(Time.now - 60 * 60 * 24 * 31 - 1)
      expect { nx.wait }.to hop("refresh_certificates")
    end
  end

  describe "#refresh_certificates" do
    it "creates new certificates and hops to wait after incr_reconfigure" do
      cert = nx.minio_server.cert
      cert_key = nx.minio_server.cert_key
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_1").and_return(cert_1)
      expect(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_1").and_return(key_1)
      expect(Util).to receive(:create_certificate).with(create_certificate_payload).and_return([instance_double(OpenSSL::X509::Certificate, to_pem: "cert"), instance_double(OpenSSL::PKey::EC, to_pem: "cert_key")])
      expect(nx.minio_server).to receive(:update).and_call_original
      expect(nx).to receive(:incr_reconfigure)

      expect { nx.refresh_certificates }.to hop("wait")
      expect(nx.minio_server.cert).not_to eq cert
      expect(nx.minio_server.cert_key).not_to eq cert_key
    end

    it "creates new certificates from root_cert_2 if root_cert_1 is about to expire" do
      expect(Time).to receive(:now).and_return(Time.now + 60 * 60 * 24 * 365 * 4 + 1).at_least(:once)
      cert = nx.minio_server.cert
      cert_key = nx.minio_server.cert_key
      cert_2 = instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 5)
      key_2 = instance_double(OpenSSL::PKey::EC)
      expect(cert_1).to receive(:not_after).and_return(Time.now + 60 * 60 * 24 * 365 * 1 - 1)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_1").and_return(cert_1)
      expect(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_1").and_return(key_1)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root_cert_2").and_return(cert_2)
      expect(OpenSSL::PKey::EC).to receive(:new).with("root_cert_key_2").and_return(key_2)
      create_certificate_payload[:issuer_cert] = cert_2
      create_certificate_payload[:issuer_key] = key_2
      expect(Util).to receive(:create_certificate).with(create_certificate_payload).and_return([instance_double(OpenSSL::X509::Certificate, to_pem: "cert"), instance_double(OpenSSL::PKey::EC, to_pem: "cert_key")])
      expect(nx.minio_server).to receive(:update).and_call_original
      expect(nx).to receive(:incr_reconfigure)

      expect(nx.minio_server.cluster).to receive(:root_cert_2).and_call_original
      expect(nx.minio_server.cluster).to receive(:root_cert_key_2).and_call_original

      expect { nx.refresh_certificates }.to hop("wait")
      expect(nx.minio_server.cert).not_to eq cert
      expect(nx.minio_server.cert_key).not_to eq cert_key
    end
  end

  describe "#wait_reconfigure" do
    it "donates if reconfigure continues" do
      Strand.create(parent_id: st.id, prog: "SetupMinio", label: "configure_minio", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_reconfigure }.to nap(120)
    end

    it "hops to wait if reconfigure is done" do
      expect { nx.wait_reconfigure }.to hop("wait")
    end
  end

  describe "#unavailable" do
    it "hops to wait if the server is available" do
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.unavailable }.to hop("wait")
    end

    it "buds minio_restart if the server is not available" do
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:bud).with(described_class, {}, :minio_restart)
      expect { nx.unavailable }.to nap(5)
    end

    it "does not bud minio_restart if there is already one restart going on" do
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.unavailable }.to nap(5)
      expect(nx).not_to receive(:bud).with(described_class, {}, :minio_restart)
      expect { nx.unavailable }.to nap(5)
    end
  end

  describe "#destroy" do
    it "triggers vm destroy, nic, sshable and minio server destroy" do
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(nx.minio_server.vm.sshable).to receive(:destroy)
      expect(nx.minio_server.vm.nics.first).to receive(:incr_destroy)
      expect(nx.minio_server.vm).to receive(:incr_destroy)
      expect(nx.minio_server).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "minio server destroyed"})
    end

    it "triggers vm destroy, nic, sshable, dnszone delete record and minio server destroy if dnszone exits" do
      DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(nx.minio_server.vm.sshable).to receive(:destroy)
      expect(nx.minio_server.vm.nics.first).to receive(:incr_destroy)
      expect(nx.minio_server.vm).to receive(:incr_destroy)
      expect(nx.minio_server).to receive(:destroy)
      expect(nx.minio_server.cluster.dns_zone).to receive(:delete_record).with(record_name: nx.cluster.hostname, type: "A", data: nil)
      expect { nx.destroy }.to exit({"msg" => "minio server destroyed"})
    end

    it "if dnszone exits and vm has ipv4, it gets deleted properly" do
      DnsZone.create(project_id: minio_project.id, name: Config.minio_host_name)
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(nx.minio_server.vm.sshable).to receive(:destroy)
      expect(nx.minio_server.vm.nics.first).to receive(:incr_destroy)
      expect(nx.minio_server.vm).to receive(:incr_destroy)
      expect(nx.minio_server.vm).to receive(:ephemeral_net4).and_return("10.10.10.10")
      expect(nx.minio_server).to receive(:destroy)
      expect(nx.minio_server.cluster.dns_zone).to receive(:delete_record).with(record_name: nx.cluster.hostname, type: "A", data: "10.10.10.10")
      expect { nx.destroy }.to exit({"msg" => "minio server destroyed"})
    end
  end

  describe "#before_run" do
    it "hops to destroy if strand is not destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if strand is destroy" do
      nx.strand.update(label: "destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if destroy is not set" do
      expect(nx).to receive(:when_destroy_set?).and_return(false)
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if strand label is destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "pops additional operations from stack" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect(nx.strand.stack).to receive(:count).and_return(2)
      expect { nx.before_run }.to exit({"msg" => "operation is cancelled due to the destruction of the minio server"})
    end
  end

  describe "#available?" do
    before do
      allow(nx.minio_server).to receive(:cert).and_return("cert")
    end

    it "returns true if initial provisioning is set" do
      expect(nx.minio_server).to receive(:initial_provisioning_set?).and_return(true)
      expect(nx.available?).to be(true)
    end

    it "returns true if health check is successful" do
      expect(nx.minio_server.vm).to receive(:ephemeral_net4).and_return("1.2.3.4")
      stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok"}]}]}))
      expect(nx.available?).to be(true)
    end

    it "returns false if health check is unsuccessful" do
      expect(nx.minio_server.vm).to receive(:ephemeral_net4).and_return("1.2.3.4")
      stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "offline", endpoint: "1.2.3.4:9000"}]}))
      expect(nx.available?).to be(false)
    end

    it "returns false if health check raises an exception" do
      expect(Minio::Client).to receive(:new).and_raise(RuntimeError)
      expect(nx.available?).to be(false)
    end
  end
end
