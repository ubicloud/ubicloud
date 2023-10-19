# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Postgres::PostgresResourceNexus do
  subject(:nx) { described_class.new(Strand.new(id: PostgresResource.generate_uuid)) }

  let(:project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

  let(:postgres_resource) { instance_double(PostgresResource, id: "0eb058bb-960e-46fe-aab7-3717f164ab25", ubid: "pgubid", project_id: project.id, server_name: "pg-server-name", location: "hetzner-hel1", target_storage_size_gib: 100) }
  let(:vm) { instance_double(Vm, id: "788525ed-d6f0-4937-a844-323d4fd91946", cores: 1) }
  let(:sshable) { instance_double(Sshable) }

  before do
    allow(vm).to receive(:sshable).and_return(sshable)
    allow(postgres_resource).to receive_messages(project: project, vm: vm)
    allow(nx).to receive(:postgres_resource).and_return(postgres_resource)
  end

  describe ".assemble" do
    let(:postgres_project) { Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) } }

    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    it "validates input" do
      expect {
        described_class.assemble(project_id: "26820e05-562a-4e25-a51b-de5f78bd00af", location: "hetzner-hel1", server_name: "pg-server-name", target_vm_size: "standard-2", target_storage_size_gib: 100)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(project_id: project.id, location: "hetzner-xxx", server_name: "pg-server-name", target_vm_size: "standard-2", target_storage_size_gib: 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: provider"

      expect {
        described_class.assemble(project_id: project.id, location: "hetzner-hel1", server_name: "pg/server/name", target_vm_size: "standard-2", target_storage_size_gib: 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(project_id: project.id, location: "hetzner-hel1", server_name: "pg-server-name", target_vm_size: "standard-128", target_storage_size_gib: 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: size"
    end

    it "creates postgres resource and vm with sshable" do
      st = described_class.assemble(project_id: project.id, location: "hetzner-hel1", server_name: "pg-server-name", target_vm_size: "standard-2", target_storage_size_gib: 100)

      postgres_resource = PostgresResource[st.id]
      expect(postgres_resource).not_to be_nil
      expect(postgres_resource.vm).not_to be_nil
      expect(postgres_resource.vm.sshable).not_to be_nil
    end
  end

  describe "#before_run" do
    it "hops to destroy and stops billing records when needed" do
      br = instance_double(BillingRecord)
      expect(br).to receive(:finalize).twice
      expect(postgres_resource).to receive(:active_billing_records).and_return([br, br])
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(vm).to receive(:strand).and_return(Strand.new(label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "hops if vm is ready" do
      expect(postgres_resource).to receive(:incr_initial_provisioning)
      expect(vm).to receive(:strand).and_return(Strand.new(label: "wait"))
      expect { nx.start }.to hop("bootstrap_rhizome")
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process" do
      expect(nx).to receive(:register_deadline)
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => vm.id, "user" => "ubi"})
      expect { nx.bootstrap_rhizome }.to hop("create_dns_record")
    end
  end

  describe "#create_dns_record" do
    it "creates dns records and hops" do
      expect(vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
      expect(postgres_resource).to receive(:hostname).and_return("pg-server-name.postgres.ubicloud.com.")
      dns_zone = instance_double(DnsZone)
      expect(dns_zone).to receive(:insert_record).with(record_name: "pg-server-name.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.1.1.1")
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect { nx.create_dns_record }.to hop("wait_bootstrap_rhizome")
    end

    it "hops even if dns zone is not configured" do
      expect(nx).to receive(:dns_zone).and_return(nil)
      expect { nx.create_dns_record }.to hop("wait_bootstrap_rhizome")
    end
  end

  describe "#wait_bootstrap_rhizome" do
    before { expect(nx).to receive(:reap) }

    it "hops to mount_data_disk if there are no sub-programs running" do
      expect(nx).to receive(:leaf?).and_return true

      expect { nx.wait_bootstrap_rhizome }.to hop("mount_data_disk")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return false
      expect(nx).to receive(:donate).and_call_original

      expect { nx.wait_bootstrap_rhizome }.to nap(0)
    end
  end

  describe "#mount_data_disk" do
    it "formats data disk if format command is not sent yet or failed" do
      expect(vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")]).twice
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo mkfs --type ext4 /dev/vdb' format_disk").twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("NotStarted")
      expect { nx.mount_data_disk }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Failed")
      expect { nx.mount_data_disk }.to nap(5)
    end

    it "mounts data disk if format disk is succeeded and hops to install_postgres" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Succeeded")
      expect(vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")])
      expect(sshable).to receive(:cmd).with("sudo mkdir -p /dat")
      expect(sshable).to receive(:cmd).with("sudo common/bin/add_to_fstab /dev/vdb /dat ext4 defaults 0 0")
      expect(sshable).to receive(:cmd).with("sudo mount /dev/vdb /dat")
      expect { nx.mount_data_disk }.to hop("install_postgres")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check format_disk").and_return("Unknown")
      expect { nx.mount_data_disk }.to nap(5)
    end
  end

  describe "#install_postgres" do
    it "triggers install_postgres if install_postgres command is not sent yet or failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/install_postgres' install_postgres").twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("NotStarted")
      expect { nx.install_postgres }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Failed")
      expect { nx.install_postgres }.to nap(5)
    end

    it "hops to initialize_certificates if install_postgres command is succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Succeeded")
      expect { nx.install_postgres }.to hop("initialize_certificates")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check install_postgres").and_return("Unknown")
      expect { nx.install_postgres }.to nap(5)
    end
  end

  describe "#initialize_certificates" do
    let(:postgres_resource) {
      PostgresResource.create_with_id(
        project_id: "c9764635-03c6-4d1e-8634-6c86e1b69150",
        location: "hetzner-hel1",
        server_name: "pg-server-name",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100,
        superuser_password: "dummy-password"
      )
    }

    it "hops to configure after creating certificates" do
      expect(Config).to receive(:postgres_service_hostname).and_return("postgres.ubicloud.com").twice
      expect(Util).to receive(:create_certificate).with(hash_including(subject: "/C=US/O=Ubicloud/CN=#{postgres_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)).and_call_original
      expect(Util).to receive(:create_certificate).with(hash_including(subject: "/C=US/O=Ubicloud/CN=#{postgres_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)).and_call_original
      expect(Util).to receive(:create_certificate).with(hash_including(subject: "/C=US/O=Ubicloud/CN=#{postgres_resource.ubid} Server Certificate", duration: 60 * 60 * 24 * 30 * 6)).and_call_original

      expect(sshable).to receive(:cmd).at_least(:once)
      expect { nx.initialize_certificates }.to hop("configure")
    end
  end

  describe "#refresh_certificates" do
    let(:postgres_resource) {
      PostgresResource.create_with_id(
        project_id: "c9764635-03c6-4d1e-8634-6c86e1b69150",
        location: "hetzner-hel1",
        server_name: "pg-server-name",
        target_vm_size: "standard-2",
        target_storage_size_gib: 100,
        superuser_password: "dummy-password",
        root_cert_1: "root cert 1",
        root_cert_2: "root cert 2",
        server_cert: "server cert"
      )
    }

    it "rotates root certificate if root_cert_1 is close to expiration" do
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 30 * 4))
      expect(OpenSSL::X509::Certificate).to receive(:new).with("server cert").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 30 * 4))
      expect(nx).to receive(:create_root_certificate).with(hash_including(duration: 60 * 60 * 24 * 365 * 10))

      expect { nx.refresh_certificates }.to hop("wait")
    end

    it "rotates server certificate if it is close to expiration" do
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 365 * 4))
      expect(OpenSSL::X509::Certificate).to receive(:new).with("server cert").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 29))
      expect(nx).to receive(:create_server_certificate)
      expect(sshable).to receive(:cmd).at_least(:once)

      expect { nx.refresh_certificates }.to hop("wait")
    end

    it "rotates server certificate using root_cert_2 if root_cert_1 is close to expiration" do
      expect(Config).to receive(:postgres_service_hostname).and_return("postgres.ubicloud.com").twice
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").twice.and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 360))
      root_cert_2 = instance_double(OpenSSL::X509::Certificate)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 2").and_return(root_cert_2)
      expect(OpenSSL::X509::Certificate).to receive(:new).with("server cert").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 29))

      expect(Util).to receive(:create_certificate).with(hash_including(issuer_cert: root_cert_2)).and_return([instance_double(OpenSSL::X509::Certificate, to_pem: "server cert")])
      expect(sshable).to receive(:cmd).at_least(:once)

      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#configure" do
    it "triggers configure if configure command is not sent yet or failed" do
      expect(postgres_resource).to receive(:configure_hash).and_return("dummy-configure-hash").twice
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo postgres/bin/configure' configure", stdin: JSON.generate("dummy-configure-hash")).twice

      # NotStarted
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("NotStarted")
      expect { nx.configure }.to nap(5)

      # Failed
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Failed")
      expect { nx.configure }.to nap(5)
    end

    it "hops to update_superuser_password if configure command is succeeded during the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Succeeded")
      expect { nx.configure }.to hop("update_superuser_password")
    end

    it "hops to wait if configure command is succeeded at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Succeeded")
      expect { nx.configure }.to hop("wait")
    end

    it "naps if script return unknown status" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check configure").and_return("Unknown")
      expect { nx.configure }.to nap(5)
    end
  end

  describe "#update_superuser_password" do
    it "updates password and hops to restart during the initial provisioning" do
      expect(postgres_resource).to receive(:superuser_password).and_return("pass")
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(sshable).to receive(:cmd).with("sudo -u postgres psql", stdin: /log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_superuser_password }.to hop("restart")
    end

    it "updates password and hops to wait at times other than the initial provisioning" do
      expect(postgres_resource).to receive(:superuser_password).and_return("pass")
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(sshable).to receive(:cmd).with("sudo -u postgres psql", stdin: /log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_superuser_password }.to hop("wait")
    end
  end

  describe "#restart" do
    it "restarts and hops to create_billing_record during the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(nx).to receive(:decr_restart)
      expect(sshable).to receive(:cmd).with("sudo postgres/bin/restart")
      expect { nx.restart }.to hop("create_billing_record")
    end

    it "restarts and hops to wait at times other than the initial provisioning" do
      expect(nx).to receive(:when_initial_provisioning_set?)
      expect(nx).to receive(:decr_restart)
      expect(sshable).to receive(:cmd).with("sudo postgres/bin/restart")
      expect { nx.restart }.to hop("wait")
    end
  end

  describe "#create_billing_record" do
    it "creates billing record for cores and storage then hops" do
      expect(nx).to receive(:decr_initial_provisioning)

      expect(BillingRecord).to receive(:create_with_id).with(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.server_name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresCores", "standard", postgres_resource.location)["id"],
        amount: vm.cores
      )

      expect(BillingRecord).to receive(:create_with_id).with(
        project_id: postgres_resource.project_id,
        resource_id: postgres_resource.id,
        resource_name: postgres_resource.server_name,
        billing_rate_id: BillingRate.from_resource_properties("PostgresStorage", "standard", postgres_resource.location)["id"],
        amount: postgres_resource.target_storage_size_gib
      )

      expect { nx.create_billing_record }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect(postgres_resource).to receive(:certificate_last_checked_at).and_return(Time.now)
      expect { nx.wait }.to nap(30)
    end

    it "hops to refresh_certificates if the certificate is checked more than 1 months ago" do
      expect(postgres_resource).to receive(:certificate_last_checked_at).and_return(Time.now - 60 * 60 * 24 * 30 - 1)
      expect { nx.wait }.to hop("refresh_certificates")
    end
  end

  describe "#destroy" do
    it "triggers vm deletion and waits until it is deleted" do
      dns_zone = instance_double(DnsZone)
      expect(postgres_resource).to receive(:hostname)
      expect(dns_zone).to receive(:delete_record)
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(vm).to receive(:private_subnets).and_return([])
      expect(vm).to receive(:incr_destroy)
      expect { nx.destroy }.to nap(5)

      expect(vm).to receive(:private_subnets).and_return([])
      expect(vm).to receive(:incr_destroy)
      expect { nx.destroy }.to nap(5)

      expect(postgres_resource).to receive(:vm).and_return(nil)
      expect(postgres_resource).to receive(:dissociate_with_project)
      expect(postgres_resource).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "postgres resource is deleted"})
    end

    it "completes destroy even if dns zone is not configured" do
      expect(nx).to receive(:dns_zone).and_return(nil)
      expect(postgres_resource).to receive(:vm).and_return(nil)
      expect(postgres_resource).to receive(:dissociate_with_project)
      expect(postgres_resource).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "postgres resource is deleted"})
    end
  end

  describe "#dns_zone" do
    it "fetches dns zone from database only once" do
      expect(DnsZone).to receive(:where).exactly(:once).and_return([true])

      nx.dns_zone
      nx.dns_zone
    end
  end
end
