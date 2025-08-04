# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::VictoriaMetrics::VictoriaMetricsResourceNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:victoria_metrics_resource) {
    instance_double(
      VictoriaMetricsResource,
      ubid: "vrnjbsrja7ka4nk7ptcg03szg2",
      location_id: Location::HETZNER_FSN1_ID,
      root_cert_1: "root cert 1",
      root_cert_key_1: nil,
      root_cert_2: "root cert 2",
      root_cert_key_2: nil,
      certificate_last_checked_at: Time.now,
      private_subnet: instance_double(
        PrivateSubnet,
        firewalls: [instance_double(Firewall)],
        incr_destroy: nil
      ),
      servers: [instance_double(
        VictoriaMetricsServer,
        vm: instance_double(
          Vm,
          family: "standard",
          vcpus: 2,
          vm_host: instance_double(VmHost, id: "dd9ef3e7-6d55-8371-947f-a8478b42a17d"),
          private_subnets: [instance_double(PrivateSubnet, id: "627a23ee-c1fb-86d9-a261-21cc48415916")],
          display_state: "running"
        )
      )]
    ).as_null_object
  }

  before do
    allow(nx).to receive(:victoria_metrics_resource).and_return(victoria_metrics_resource)

    victoria_metrics_project = Project.create(name: "default")
    allow(Config).to receive(:victoria_metrics_service_project_id).and_return(victoria_metrics_project.id)
  end

  describe ".assemble" do
    let(:victoria_metrics_project) { Project.create(name: "default") }
    let(:private_location) {
      loc = Location.create(
        name: "us-west-2",
        display_name: "aws-us-west-2",
        ui_name: "aws-us-west-2",
        visible: true,
        provider: "aws",
        project_id: victoria_metrics_project.id
      )
      LocationCredential.create(
        access_key: "access-key-id",
        secret_key: "secret-access-key"
      ) { it.id = loc.id }
      loc
    }

    it "validates input" do
      expect {
        described_class.assemble("26820e05-562a-4e25-a51b-de5f78bd00af", "vm-name", Location::HETZNER_FSN1_ID, "admin", "standard-2", 128)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(victoria_metrics_project.id, "vm/server/name", nil, "admin", "standard-2", 128)
      }.to raise_error RuntimeError, "No existing location"

      expect {
        described_class.assemble(victoria_metrics_project.id, "vm/server/name", Location::HETZNER_FSN1_ID, "admin", "standard-2", 128)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(victoria_metrics_project.id, "vm-name", Location::HETZNER_FSN1_ID, "admin", "standard-128", 128)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: size"

      expect {
        described_class.assemble(victoria_metrics_project.id, "vm-name", Location::HETZNER_FSN1_ID, "admin", "standard-2", 128)
      }.not_to raise_error

      private_location.update(project_id: victoria_metrics_project.id)
      described_class.assemble(victoria_metrics_project.id, "vm-name", private_location.id, "admin", "standard-2", 128)
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end

    it "does not hop to destroy if already in the wait_servers_destroyed state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("wait_servers_destroyed")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#wait_servers" do
    it "naps if servers not ready" do
      expect(victoria_metrics_resource.servers).to all(receive(:strand).and_return(instance_double(Strand, label: "start")))

      expect { nx.wait_servers }.to nap(10)
    end

    it "hops if servers are ready" do
      expect(victoria_metrics_resource.servers).to all(receive(:strand).and_return(instance_double(Strand, label: "wait")))
      expect { nx.wait_servers }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to refresh_certificates if certificate was checked more than 1 month ago" do
      expect(victoria_metrics_resource).to receive(:certificate_last_checked_at).and_return(Time.now - 60 * 60 * 24 * 31)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to reconfigure when reconfigure is set" do
      expect(victoria_metrics_resource).to receive(:certificate_last_checked_at).and_return(Time.now)
      expect(nx).to receive(:when_reconfigure_set?).and_yield
      expect { nx.wait }.to hop("reconfigure")
    end

    it "naps if no action needed" do
      expect(victoria_metrics_resource).to receive(:certificate_last_checked_at).and_return(Time.now)
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
    end
  end

  describe "#refresh_certificates" do
    it "rotates root certificate if root_cert_1 is close to expiration" do
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 30 * 4))

      expect(Util).to receive(:create_root_certificate).with(duration: 60 * 60 * 24 * 365 * 10, common_name: "#{victoria_metrics_resource.ubid} Root Certificate Authority")
      expect(victoria_metrics_resource.servers).to all(receive(:incr_reconfigure))

      expect(victoria_metrics_resource).to receive(:certificate_last_checked_at=).with(anything)
      expect(victoria_metrics_resource).to receive(:save_changes)

      expect { nx.refresh_certificates }.to hop("wait")
    end

    it "does not rotate certificates if not close to expiration" do
      expect(OpenSSL::X509::Certificate).to receive(:new).with("root cert 1").and_return(instance_double(OpenSSL::X509::Certificate, not_after: Time.now + 60 * 60 * 24 * 30 * 6))

      expect(Util).not_to receive(:create_root_certificate)
      expect(victoria_metrics_resource.servers).not_to include(receive(:incr_reconfigure))

      expect(victoria_metrics_resource).to receive(:certificate_last_checked_at=).with(anything)
      expect(victoria_metrics_resource).to receive(:save_changes)

      expect { nx.refresh_certificates }.to hop("wait")
    end
  end

  describe "#reconfigure" do
    it "triggers server reconfiguration and restart" do
      expect(nx).to receive(:decr_reconfigure)
      expect(victoria_metrics_resource.servers).to all(receive(:incr_reconfigure))
      expect(victoria_metrics_resource.servers).to all(receive(:incr_restart))

      expect { nx.reconfigure }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "triggers server deletion and waits until it is deleted" do
      expect(nx).to receive(:register_deadline).with(nil, 10 * 60)
      expect(nx).to receive(:decr_destroy)
      expect(victoria_metrics_resource.private_subnet.firewalls).to all(receive(:destroy))
      expect(victoria_metrics_resource.private_subnet).to receive(:incr_destroy)
      expect(victoria_metrics_resource.servers).to all(receive(:incr_destroy))

      expect { nx.destroy }.to hop("wait_servers_destroyed")
    end
  end

  describe "#wait_servers_destroyed" do
    it "naps if servers still exist" do
      expect(victoria_metrics_resource).to receive(:servers).and_return([instance_double(VictoriaMetricsServer)])

      expect { nx.wait_servers_destroyed }.to nap(10)
    end

    it "destroys the resource and pops when all servers are gone" do
      expect(victoria_metrics_resource).to receive(:servers).and_return([])
      expect(victoria_metrics_resource).to receive(:destroy)

      expect { nx.wait_servers_destroyed }.to exit({"msg" => "destroyed"})
    end
  end
end
