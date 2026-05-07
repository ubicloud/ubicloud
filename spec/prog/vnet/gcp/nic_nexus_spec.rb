# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::NicNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:location_credential) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }

  let(:gcp_vpc) {
    vpc = GcpVpc.create(
      project_id: project.id,
      location_id: location.id,
      name: "ubicloud-#{project.ubid}-#{location.ubid}",
      network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/12345",
    )
    Strand.create_with_id(vpc, prog: "Vnet::Gcp::VpcNexus", label: "wait")
    vpc
  }

  let(:private_subnet) {
    location_credential
    gcp_vpc
    ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
    DB[:private_subnet_gcp_vpc].insert(private_subnet_id: ps.id, gcp_vpc_id: gcp_vpc.id)
    ps.strand.update(label: "wait")
    ps
  }

  let(:nic) {
    Prog::Vnet::NicNexus.assemble(private_subnet.id, name: "test-nic").subject
  }

  let(:st) { nic.strand }
  let(:addresses_client) { instance_double(Google::Cloud::Compute::V1::Addresses::Rest::Client) }
  let(:region_ops_client) { instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client) }

  before do
    allow(nx.send(:credential)).to receive_messages(addresses_client:, region_operations_client: region_ops_client)
  end

  describe "#start" do
    it "creates a NicGcpResource with network config and hops to allocate_static_ip" do
      expect { nx.start }.to hop("allocate_static_ip")
      gcp_res = NicGcpResource[nic.id]
      expect(gcp_res).not_to be_nil
      expect(gcp_res.vpc_name).to eq("ubicloud-#{private_subnet.project.ubid}-#{private_subnet.location.ubid}")
      expect(gcp_res.subnet_name).to eq("ubicloud-#{private_subnet.ubid}")
    end
  end

  describe "#allocate_static_ip" do
    before do
      NicGcpResource.create_with_id(nic, vpc_name: "ubicloud-test-net", subnet_name: "ubicloud-test-sub")
    end

    it "logs and naps if address name exceeds 63 characters" do
      # The outer before-block memoizes nx.nic via nx.credential, so update the cached instance directly.
      nx.nic.update(name: "a" * 60)
      expect(Clog).to receive(:emit).with("GCP address name too long", hash_including(:address_name, :length)).and_call_original
      expect { nx.allocate_static_ip }.to nap(30)
    end

    it "reserves a new static IP and hops to wait_allocate_ip" do
      expect(Config).to receive(:provider_resource_tag_value).and_return("314159")
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-addr-123")
      expect(addresses_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:region]).to eq("us-central1")
        expect(args[:address_resource].name).to eq("ubicloud-#{nic.name}")
        expect(args[:address_resource].address_type).to eq("EXTERNAL")
        expect(args[:address_resource].network_tier).to eq("STANDARD")
        expect(args[:address_resource].labels.to_h).to eq("ubicloud" => "314159")
        op
      end

      expect { nx.allocate_static_ip }.to hop("wait_allocate_ip")
      expect(st.reload.stack.first.dig("allocate_ip", "name")).to eq("op-addr-123")
      expect(st.stack.first["gcp_address_name"]).to eq("ubicloud-#{nic.name}")
    end

    it "handles AlreadyExistsError on insert by falling back to get" do
      expect(addresses_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))

      addr = Google::Cloud::Compute::V1::Address.new(address: "35.192.0.3")
      expect(addresses_client).to receive(:get)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(addr)
      expect(Clog).to receive(:emit).with("GCP static IP created", hash_including(gcp_static_ip_created: "ubicloud-#{nic.name}@us-central1")).and_call_original

      expect { nx.allocate_static_ip }.to hop("wait")
      expect(nic.nic_gcp_resource.reload.static_ip.to_s).to eq("35.192.0.3")
    end
  end

  describe "#wait_allocate_ip" do
    before do
      NicGcpResource.create_with_id(nic, vpc_name: "ubicloud-test-net", subnet_name: "ubicloud-test-sub")
      refresh_frame(nx, new_values: {
        "allocate_ip" => {"name" => "op-addr-123", "scope" => "region", "scope_value" => "us-central1"},
        "gcp_address_name" => "ubicloud-#{nic.name}",
      })
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
      expect(Clog).to receive(:emit).with("GCP static IP created", hash_including(gcp_static_ip_created: "ubicloud-#{nic.name}@us-central1")).and_call_original

      expect { nx.wait_allocate_ip }.to hop("wait")
      expect(nic.nic_gcp_resource.reload.static_ip.to_s).to eq("35.192.0.1")
      expect(nic.nic_gcp_resource.address_name).to eq("ubicloud-#{nic.name}")
    end

    it "raises if reservation fails" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
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
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
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
      expect(nic.nic_gcp_resource.reload.static_ip.to_s).to eq("35.192.0.5")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end
  end

  describe "#destroy" do
    it "releases static IP and hops to wait_release_ip" do
      NicGcpResource.create_with_id(nic, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1", vpc_name: "ubicloud-test-net", subnet_name: "ubicloud-test-sub")

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-addr")
      expect(addresses_client).to receive(:delete)
        .with(project: "test-gcp-project", region: "us-central1", address: "ubicloud-#{nic.name}")
        .and_return(delete_op)

      expect { nx.destroy }.to hop("wait_release_ip")
      expect(st.reload.stack.first.dig("release_ip", "name")).to eq("op-delete-addr")
    end

    it "handles already-deleted static IP" do
      NicGcpResource.create_with_id(nic, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1", vpc_name: "ubicloud-test-net", subnet_name: "ubicloud-test-sub")

      expect(addresses_client).to receive(:delete)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.destroy }.to hop("finalize_destroy")
    end

    it "destroys nic even without NicGcpResource" do
      expect { nx.destroy }.to hop("finalize_destroy")
    end

    it "naps when IP release operation is still running" do
      NicGcpResource.create_with_id(nic, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1", vpc_name: "ubicloud-test-net", subnet_name: "ubicloud-test-sub")
      refresh_frame(nx, new_values: {"release_ip" => {"name" => "op-delete-running", "scope" => "region", "scope_value" => "us-central1"}})

      running_op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(region_ops_client).to receive(:get).and_return(running_op)

      expect { nx.wait_release_ip }.to nap(5)
    end

    it "completes IP release and hops to finalize_destroy" do
      refresh_frame(nx, new_values: {"release_ip" => {"name" => "op-delete-ok", "scope" => "region", "scope_value" => "us-central1"}})

      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(region_ops_client).to receive(:get).and_return(done_op)

      expect { nx.wait_release_ip }.to hop("finalize_destroy")
    end

    it "raises when delete LRO fails in wait_release_ip, leaving NicGcpResource intact for retry" do
      NicGcpResource.create_with_id(nic, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1", vpc_name: "ubicloud-test-net", subnet_name: "ubicloud-test-sub")
      refresh_frame(nx, new_values: {"release_ip" => {"name" => "op-delete-fail", "scope" => "region", "scope_value" => "us-central1"}})

      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      failed_op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(region_ops_client).to receive(:get).and_return(failed_op)

      expect { nx.wait_release_ip }.to raise_error(RuntimeError, /static IP deletion failed/)
      expect(NicGcpResource[nic.id]).not_to be_nil
    end
  end

  describe "#finalize_destroy" do
    it "destroys NicGcpResource and NIC" do
      NicGcpResource.create_with_id(nic, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.1", vpc_name: "ubicloud-test-net", subnet_name: "ubicloud-test-sub")

      expect { nx.finalize_destroy }.to exit({"msg" => "nic deleted"})
      expect(NicGcpResource[nic.id]).to be_nil
      expect(Nic[nic.id]).to be_nil
    end

    it "destroys NIC even without NicGcpResource" do
      expect { nx.finalize_destroy }.to exit({"msg" => "nic deleted"})
      expect(Nic[nic.id]).to be_nil
    end
  end
end
