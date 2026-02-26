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
  let(:region_ops_client) { instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client) }

  before do
    allow(nx).to receive(:nic).and_return(nic)
    allow(location_credential).to receive_messages(addresses_client:, region_operations_client: region_ops_client)
    nx.instance_variable_set(:@credential, location_credential)
  end

  describe "#start" do
    it "creates a NicGcpResource with network config and hops to allocate_static_ip" do
      expect { nx.start }.to hop("allocate_static_ip")
      gcp_res = NicGcpResource[nic.id]
      expect(gcp_res).not_to be_nil
      expect(gcp_res.network_name).to eq("ubicloud-gcp-us-central1")
      expect(gcp_res.subnet_name).to eq("ubicloud-#{private_subnet.ubid}")
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

    it "reserves a new static IP and hops to wait_allocate_ip" do
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-addr-123")
      expect(addresses_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:region]).to eq("us-central1")
        expect(args[:address_resource].name).to eq("ubicloud-#{nic.name}")
        expect(args[:address_resource].address_type).to eq("EXTERNAL")
        expect(args[:address_resource].network_tier).to eq("STANDARD")
        op
      end

      expect { nx.allocate_static_ip }.to hop("wait_allocate_ip")
      expect(st.reload.stack.first["gcp_op_name"]).to eq("op-addr-123")
      expect(st.stack.first["gcp_address_name"]).to eq("ubicloud-#{nic.name}")
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
  end

  describe "#wait_allocate_ip" do
    before do
      NicGcpResource.create_with_id(nic.id)
      st.stack.first["gcp_op_name"] = "op-addr-123"
      st.stack.first["gcp_op_scope"] = "region"
      st.stack.first["gcp_op_scope_value"] = "us-central1"
      st.stack.first["gcp_address_name"] = "ubicloud-#{nic.name}"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(region_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_allocate_ip }.to nap(5)
    end

    it "fetches address and hops to wait when operation completes" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(region_ops_client).to receive(:get).and_return(op)

      addr = Google::Cloud::Compute::V1::Address.new(address: "35.192.0.1")
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(addr)

      expect { nx.wait_allocate_ip }.to hop("wait")
      expect(nic.nic_gcp_resource.reload.static_ip).to eq("35.192.0.1")
      expect(nic.nic_gcp_resource.address_name).to eq("ubicloud-#{nic.name}")
    end

    it "raises if reservation fails" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(region_ops_client).to receive(:get).and_return(op)
      expect(addresses_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.wait_allocate_ip }.to raise_error(RuntimeError, /static IP.*creation failed/)
    end

    it "recovers if LRO errors but address was created" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "transient")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(region_ops_client).to receive(:get).and_return(op)

      addr = Google::Cloud::Compute::V1::Address.new(address: "35.192.0.5")
      # First get during error check succeeds (address exists)
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(addr)
      # Second get for fetching address details
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(addr)

      expect { nx.wait_allocate_ip }.to hop("wait")
      expect(nic.nic_gcp_resource.reload.static_ip).to eq("35.192.0.5")
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

      expect(addresses_client).to receive(:delete)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")

      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
      expect(NicGcpResource[nic.id]).to be_nil
    end

    it "handles already-deleted static IP" do
      NicGcpResource.create_with_id(nic.id, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1")

      expect(addresses_client).to receive(:delete)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
    end

    it "destroys nic even without NicGcpResource" do
      expect { nx.destroy }.to exit({"msg" => "nic deleted"})
    end
  end
end
