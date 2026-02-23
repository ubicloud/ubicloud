# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic.id, "exclude_availability_zones" => [], "availability_zone" => nil}], label: "start")
  }

  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:location_credential) {
    LocationCredential.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }

  let(:private_subnet) {
    location_credential
    ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
    ps.strand.update(label: "wait")
    ps
  }

  let(:nic) {
    n = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "test-nic").subject
    n
  }

  let(:addresses_client) { instance_double(Google::Cloud::Compute::V1::Addresses::Rest::Client) }

  before do
    allow(nx).to receive(:nic).and_return(nic)
    allow_any_instance_of(LocationCredential).to receive(:addresses_client).and_return(addresses_client)
  end

  describe "#start" do
    it "creates a NicGcpResource and hops to allocate_static_ip" do
      expect { nx.start }.to hop("allocate_static_ip")
      expect(NicGcpResource[nic.id]).not_to be_nil
      expect(st.reload.stack.first["gcp_zone_suffix"]).to match(/\A[abc]\z/)
    end

    it "excludes specified availability zones" do
      st2 = Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic.id, "exclude_availability_zones" => ["a", "b"], "availability_zone" => nil}], label: "start")
      nx2 = described_class.new(st2)
      allow(nx2).to receive(:nic).and_return(nic)
      expect { nx2.start }.to hop("allocate_static_ip")
      expect(st2.stack.first["gcp_zone_suffix"]).to eq("c")
    end

    it "uses specified availability_zone when set" do
      st2 = Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic.id, "exclude_availability_zones" => [], "availability_zone" => "b"}], label: "start")
      nx2 = described_class.new(st2)
      allow(nx2).to receive(:nic).and_return(nic)
      expect { nx2.start }.to hop("allocate_static_ip")
      expect(st2.stack.first["gcp_zone_suffix"]).to eq("b")
    end

    it "falls back to 'a' when all zones are excluded" do
      st2 = Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic.id, "exclude_availability_zones" => ["a", "b", "c"], "availability_zone" => nil}], label: "start")
      nx2 = described_class.new(st2)
      allow(nx2).to receive(:nic).and_return(nic)
      expect { nx2.start }.to hop("allocate_static_ip")
      expect(st2.stack.first["gcp_zone_suffix"]).to eq("a")
    end
  end

  describe "#allocate_static_ip" do
    before do
      NicGcpResource.create_with_id(nic.id)
    end

    it "reserves a new static IP when none exists" do
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, error?: false)
      expect(op).to receive(:wait_until_done!)
      expect(addresses_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:region]).to eq("us-central1")
        expect(args[:address_resource].name).to eq("ubicloud-#{nic.name}")
        expect(args[:address_resource].address_type).to eq("EXTERNAL")
        expect(args[:address_resource].network_tier).to eq("STANDARD")
        op
      end

      addr = Google::Cloud::Compute::V1::Address.new(address: "35.192.0.1")
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(addr)

      expect { nx.allocate_static_ip }.to hop("wait")
      expect(nic.nic_gcp_resource.reload.static_ip).to eq("35.192.0.1")
      expect(nic.nic_gcp_resource.address_name).to eq("ubicloud-#{nic.name}")
    end

    it "uses existing static IP if already reserved" do
      addr = Google::Cloud::Compute::V1::Address.new(address: "35.192.0.2")
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(addr)

      expect(addresses_client).not_to receive(:insert)

      expect { nx.allocate_static_ip }.to hop("wait")
      expect(nic.nic_gcp_resource.reload.static_ip).to eq("35.192.0.2")
    end

    it "raises if reservation fails" do
      expect(addresses_client).to receive(:get)
        .twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, error?: true, error: "quota exceeded")
      expect(op).to receive(:wait_until_done!)
      expect(addresses_client).to receive(:insert).and_return(op)

      expect { nx.allocate_static_ip }.to raise_error(RuntimeError, /static IP.*creation failed/)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "releases static IP, destroys NicGcpResource, and pops" do
      NicGcpResource.create_with_id(nic.id, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1")

      op = instance_double(Gapic::GenericLRO::Operation, error?: false)
      expect(op).to receive(:wait_until_done!)
      expect(addresses_client).to receive(:delete)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(op)

      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
      expect(NicGcpResource[nic.id]).to be_nil
    end

    it "handles already-deleted static IP" do
      NicGcpResource.create_with_id(nic.id, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1")

      expect(addresses_client).to receive(:delete)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
    end

    it "raises when static IP release fails with non-NotFound error" do
      NicGcpResource.create_with_id(nic.id, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1")

      op = instance_double(Gapic::GenericLRO::Operation, error?: true, error: "quota exceeded")
      expect(op).to receive(:wait_until_done!)
      expect(addresses_client).to receive(:delete).and_return(op)

      expect { nx.destroy }.to raise_error(RuntimeError, /GCP static IP release failed/)
    end

    it "destroys nic even without NicGcpResource" do
      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
    end
  end
end
