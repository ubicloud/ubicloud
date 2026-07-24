# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::VictoriaMetrics::VictoriaMetricsResourceNexus do
  subject(:nx) {
    described_class.new(described_class.assemble(project.id, "test-vm", Location::HETZNER_FSN1_ID, "admin", "standard-2", 128))
  }

  let(:project) { Project.create(name: "default") }

  before do
    allow(Config).to receive(:victoria_metrics_service_project_id).and_return(project.id)
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
        project_id: victoria_metrics_project.id,
      )
      LocationCredentialAws.create(
        access_key: "access-key-id",
        secret_key: "secret-access-key",
      ) { it.id = loc.id }
      LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
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
      expect(Config).to receive(:victoria_metrics_service_project_id).and_return(victoria_metrics_project.id).at_least(:once)
      described_class.assemble(victoria_metrics_project.id, "vm-name", private_location.id, "admin", "standard-2", 128)
    end
  end

  describe "#wait_servers" do
    it "naps if servers not ready" do
      expect { nx.wait_servers }.to nap(10)
    end

    it "hops to refresh_dns_record if servers are ready" do
      nx.victoria_metrics_resource.servers.first.strand.update(label: "wait")
      expect { nx.wait_servers }.to hop("refresh_dns_record")
    end
  end

  describe "#refresh_dns_record" do
    let(:dns_zone) { DnsZone.create(project_id: project.id, name: Config.victoria_metrics_host_name) }

    before do
      vm = nx.victoria_metrics_resource.servers.first.vm
      add_ipv4_to_vm(vm, "1.2.3.4")
      vm.update(ephemeral_net6: "2a01::/64")
    end

    it "refreshes A/AAAA records when a dns_zone and representative_server are present" do
      dns_zone
      nx.incr_refresh_dns_record

      expect { nx.refresh_dns_record }.to hop("wait")

      expect(nx.victoria_metrics_resource.reload.refresh_dns_record_set?).to be false
      expect(dns_zone.records_dataset.where(type: "A", data: "1.2.3.4", tombstoned: false).count).to eq(1)
      expect(dns_zone.records_dataset.where(type: "AAAA", data: "2a01::2", tombstoned: false).count).to eq(1)
    end

    it "tombstones stale records before publishing the current address" do
      dns_zone.insert_record(record_name: nx.victoria_metrics_resource.hostname, type: "A", ttl: 10, data: "9.9.9.9")

      expect { nx.refresh_dns_record }.to hop("wait")

      expect(dns_zone.records_dataset.where(type: "A", data: "9.9.9.9", tombstoned: true).count).to eq(1)
      expect(dns_zone.records_dataset.where(type: "A", data: "1.2.3.4", tombstoned: false).count).to eq(1)
    end

    it "does nothing when no dns_zone is present" do
      expect { nx.refresh_dns_record }.to hop("wait")
    end

    it "does nothing when there is no representative_server" do
      nx.victoria_metrics_resource.servers.first.update(is_representative: false)
      dns_zone

      expect { nx.refresh_dns_record }.to hop("wait")

      expect(dns_zone.records_dataset.count).to eq(0)
    end
  end

  describe "#wait" do
    it "hops to refresh_certificates if certificate was checked more than 1 month ago" do
      nx.victoria_metrics_resource.update(certificate_last_checked_at: Time.now - 60 * 60 * 24 * 31)
      expect { nx.wait }.to hop("refresh_certificates")
    end

    it "hops to reconfigure when reconfigure is set" do
      nx.incr_reconfigure
      expect { nx.wait }.to hop("reconfigure")
    end

    it "hops to refresh_dns_record when refresh_dns_record is set" do
      nx.incr_refresh_dns_record
      expect { nx.wait }.to hop("refresh_dns_record")
    end

    it "naps if no action needed" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 30)
    end
  end

  describe "#refresh_certificates" do
    it "rotates root certificate if root_cert_1 is close to expiration" do
      cert_pem, key_pem = Util.create_root_certificate(common_name: "expiring", duration: 60 * 60 * 24 * 30 * 4)
      old_root_cert_2 = nx.victoria_metrics_resource.root_cert_2
      old_root_cert_key_2 = nx.victoria_metrics_resource.root_cert_key_2
      nx.victoria_metrics_resource.update(root_cert_1: cert_pem, root_cert_key_1: key_pem)

      expect { nx.refresh_certificates }.to hop("wait")

      nx.victoria_metrics_resource.reload
      expect(nx.victoria_metrics_resource.root_cert_1).to eq(old_root_cert_2)
      expect(nx.victoria_metrics_resource.root_cert_key_1).to eq(old_root_cert_key_2)
      expect(nx.victoria_metrics_resource.root_cert_2).not_to eq(old_root_cert_2)
      expect(nx.victoria_metrics_resource.certificate_last_checked_at).to be_within(5).of(Time.now)
      expect(nx.victoria_metrics_resource.servers.first.reload.reconfigure_set?).to be true
    end

    it "does not rotate certificates if not close to expiration" do
      cert_pem, key_pem = Util.create_root_certificate(common_name: "valid", duration: 60 * 60 * 24 * 30 * 6)
      nx.victoria_metrics_resource.update(root_cert_1: cert_pem, root_cert_key_1: key_pem)

      expect { nx.refresh_certificates }.to hop("wait")

      nx.victoria_metrics_resource.reload
      expect(nx.victoria_metrics_resource.root_cert_1).to eq(cert_pem)
      expect(nx.victoria_metrics_resource.certificate_last_checked_at).to be_within(5).of(Time.now)
      expect(nx.victoria_metrics_resource.servers.first.reload.reconfigure_set?).to be false
    end
  end

  describe "#reconfigure" do
    it "triggers server reconfiguration and restart" do
      nx.incr_reconfigure

      expect { nx.reconfigure }.to hop("wait")

      expect(nx.victoria_metrics_resource.reload.reconfigure_set?).to be false
      server = nx.victoria_metrics_resource.servers.first.reload
      expect(server.reconfigure_set?).to be true
      expect(server.restart_set?).to be true
    end
  end

  describe "#destroy" do
    it "triggers server deletion and waits until it is deleted" do
      dns_zone = DnsZone.create(project_id: project.id, name: Config.victoria_metrics_host_name)
      dns_zone.insert_record(record_name: nx.victoria_metrics_resource.hostname, type: "A", ttl: 10, data: "1.2.3.4")
      firewall = nx.victoria_metrics_resource.private_subnet.firewalls.first
      private_subnet = nx.victoria_metrics_resource.private_subnet
      server = nx.victoria_metrics_resource.servers.first
      nx.incr_destroy

      expect { nx.destroy }.to hop("wait_servers_destroyed")

      expect(nx.victoria_metrics_resource.reload.destroy_set?).to be false
      expect(dns_zone.records_dataset.where(type: "A", data: "1.2.3.4", tombstoned: true).count).to eq(1)
      expect(firewall).not_to exist
      expect(private_subnet.reload.destroy_set?).to be true
      expect(server.reload.destroy_set?).to be true
    end

    it "skips DNS cleanup when no dns_zone is present" do
      firewall = nx.victoria_metrics_resource.private_subnet.firewalls.first
      private_subnet = nx.victoria_metrics_resource.private_subnet
      server = nx.victoria_metrics_resource.servers.first
      nx.incr_destroy

      expect { nx.destroy }.to hop("wait_servers_destroyed")

      expect(nx.victoria_metrics_resource.reload.destroy_set?).to be false
      expect(firewall).not_to exist
      expect(private_subnet.reload.destroy_set?).to be true
      expect(server.reload.destroy_set?).to be true
    end
  end

  describe "#wait_servers_destroyed" do
    it "naps if servers still exist" do
      expect { nx.wait_servers_destroyed }.to nap(10)
    end

    it "destroys the resource and pops when all servers are gone" do
      resource = nx.victoria_metrics_resource
      VictoriaMetricsServer.where(victoria_metrics_resource_id: resource.id).destroy

      expect { nx.wait_servers_destroyed }.to exit({"msg" => "destroyed"})
      expect(resource).not_to exist
    end
  end
end
