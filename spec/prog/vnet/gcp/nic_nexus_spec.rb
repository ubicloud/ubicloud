# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::NicNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic.id}], label: "start")
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
    it "creates a NicGcpResource with network config, allocates firewall priority, and hops to allocate_static_ip" do
      expect { nx.start }.to hop("allocate_static_ip")
      gcp_res = NicGcpResource[nic.id]
      expect(gcp_res).not_to be_nil
      expect(gcp_res.network_name).to eq("ubicloud-gcp-us-central1")
      expect(gcp_res.subnet_name).to eq("ubicloud-#{private_subnet.ubid}")
      expect(gcp_res.firewall_base_priority).to eq(10000)
      expect(gcp_res.location_id).to eq(private_subnet.location_id)
    end

    it "allocates sequential firewall_base_priority for multiple NICs" do
      expect { nx.start }.to hop("allocate_static_ip")
      expect(NicGcpResource[nic.id].firewall_base_priority).to eq(10000)

      nic2 = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "test-nic2").subject
      st2 = Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic2.id}], label: "start")
      nx2 = described_class.new(st2)
      allow(nx2).to receive(:nic).and_return(nic2)
      nx2.instance_variable_set(:@credential, location_credential)

      expect { nx2.start }.to hop("allocate_static_ip")
      expect(NicGcpResource[nic2.id].firewall_base_priority).to eq(10064)
    end

    it "raises when VM firewall priority range is exhausted" do
      max_base = described_class::VM_MAX - described_class::VM_STRIDE + 1
      fake_ds = instance_double(Sequel::Dataset)
      allow(fake_ds).to receive_messages(where: fake_ds, exclude: fake_ds, select_map: (10000..max_base).step(64).to_a)
      allow(DB).to receive(:[]).and_call_original
      allow(DB).to receive(:[]).with(:nic_gcp_resource).and_return(fake_ds)

      expect { nx.start }.to raise_error(RuntimeError, /GCP VM firewall priority range exhausted/)
    end

    it "retries allocate_vm_firewall_priority on unique constraint violation" do
      nic_resource = NicGcpResource.create_with_id(nic.id)
      allow(NicGcpResource).to receive(:create_with_id).and_return(nic_resource)
      attempt = 0
      allow(nic_resource).to receive(:update).and_wrap_original do |m, hash|
        attempt += 1
        raise Sequel::UniqueConstraintViolation, "dup" if attempt == 1 && hash[:firewall_base_priority]
        m.call(hash)
      end

      expect { nx.start }.to hop("allocate_static_ip")
      expect(nic_resource.reload.firewall_base_priority).to eq(10000)
    end

    it "gap-fills freed slot after NIC deletion" do
      expect { nx.start }.to hop("allocate_static_ip")
      expect(NicGcpResource[nic.id].firewall_base_priority).to eq(10000)

      nic2 = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "test-nic2").subject
      st2 = Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic2.id}], label: "start")
      nx2 = described_class.new(st2)
      allow(nx2).to receive(:nic).and_return(nic2)
      nx2.instance_variable_set(:@credential, location_credential)
      expect { nx2.start }.to hop("allocate_static_ip")
      expect(NicGcpResource[nic2.id].firewall_base_priority).to eq(10064)

      # Delete first NIC's GCP resource to free slot 10000
      NicGcpResource[nic.id].destroy

      nic3 = Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "test-nic3").subject
      st3 = Strand.create(prog: "Vnet::Gcp::NicNexus", stack: [{"subject_id" => nic3.id}], label: "start")
      nx3 = described_class.new(st3)
      allow(nx3).to receive(:nic).and_return(nic3)
      nx3.instance_variable_set(:@credential, location_credential)
      expect { nx3.start }.to hop("allocate_static_ip")
      expect(NicGcpResource[nic3.id].firewall_base_priority).to eq(10000)
    end

    it "allocates last valid base without overflow" do
      # Fill all slots except the last valid base (59920)
      max_base = described_class::VM_MAX - described_class::VM_STRIDE + 1
      all_bases = (10000..max_base).step(64).to_a
      last_base = all_bases.pop

      fake_ds = instance_double(Sequel::Dataset)
      allow(fake_ds).to receive_messages(where: fake_ds, exclude: fake_ds, select_map: all_bases)
      allow(DB).to receive(:[]).and_call_original
      allow(DB).to receive(:[]).with(:nic_gcp_resource).and_return(fake_ds)

      expect { nx.start }.to hop("allocate_static_ip")
      expect(NicGcpResource[nic.id].firewall_base_priority).to eq(last_base)
      # Verify last rule doesn't exceed VM_MAX
      expect(last_base + described_class::VM_STRIDE - 1).to be <= described_class::VM_MAX
    end

    it "raises after exceeding retry limit on persistent unique constraint violations" do
      nic_resource = NicGcpResource.create_with_id(nic.id)
      allow(NicGcpResource).to receive(:create_with_id).and_return(nic_resource)
      allow(nic_resource).to receive(:update).and_wrap_original do |m, hash|
        raise Sequel::UniqueConstraintViolation, "dup" if hash.key?(:firewall_base_priority) && !hash[:firewall_base_priority].nil?
        m.call(hash)
      end

      expect { nx.start }.to raise_error(RuntimeError, /allocation failed after .* concurrent retries/)
    end

    it "silently ignores errors during nil-reset on retry" do
      nic_resource = NicGcpResource.create_with_id(nic.id)
      allow(NicGcpResource).to receive(:create_with_id).and_return(nic_resource)
      attempt = 0
      allow(nic_resource).to receive(:update).and_wrap_original do |m, hash|
        attempt += 1
        raise Sequel::UniqueConstraintViolation, "dup" if attempt == 1 && hash[:firewall_base_priority]
        raise Sequel::Error, "reset failed" if attempt == 2 && hash[:firewall_base_priority].nil?
        m.call(hash)
      end

      expect { nx.start }.to hop("allocate_static_ip")
      expect(nic_resource.reload.firewall_base_priority).to eq(10000)
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

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-addr")
      expect(addresses_client).to receive(:delete)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(delete_op)
      expect(region_ops_client).to receive(:get).with(
        project: "test-gcp-project", region: "us-central1", operation: "op-delete-addr"
      ).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))

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

    it "raises when delete LRO fails, leaving NicGcpResource intact for retry" do
      NicGcpResource.create_with_id(nic.id, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1")

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-fail")
      expect(addresses_client).to receive(:delete).and_return(delete_op)
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      failed_op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(region_ops_client).to receive(:get).and_return(failed_op)

      expect { nx.destroy }.to raise_error(RuntimeError, /op-delete-fail.*failed/)
      expect(NicGcpResource[nic.id]).not_to be_nil
    end
  end
end
