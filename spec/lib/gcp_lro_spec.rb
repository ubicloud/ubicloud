# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../spec_helper"

RSpec.describe GcpLro do
  let(:strand) { Strand.create(prog: "Vnet::Gcp::SubnetNexus", label: "start") }
  let(:credential) {
    instance_double(LocationCredential,
      project_id: "test-gcp-project",
      zone_operations_client: zone_ops_client,
      region_operations_client: region_ops_client,
      global_operations_client: global_ops_client)
  }
  let(:zone_ops_client) { instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client) }
  let(:region_ops_client) { instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client) }
  let(:global_ops_client) { instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client) }

  let(:nx) { Prog::Vnet::Gcp::SubnetNexus.new(strand) }

  before do
    allow(nx).to receive_messages(credential:, gcp_project_id: "test-gcp-project")
  end

  describe "#poll_gcp_op" do
    it "raises for unknown scope" do
      strand.stack.first["gcp_op_name"] = "op-123"
      strand.stack.first["gcp_op_scope"] = "invalid"
      strand.stack.first["gcp_op_scope_value"] = nil
      strand.modified!(:stack)
      strand.save_changes
      nx.instance_variable_set(:@frame, nil)

      expect { nx.send(:poll_gcp_op) }.to raise_error(RuntimeError, /Unknown GCP operation scope: invalid/)
    end
  end

  # rubocop:disable RSpec/VerifiedDoubles
  describe "#op_error_message" do
    it "returns string when error does not respond to :errors" do
      op = double("op", error: "simple string error")
      expect(nx.send(:op_error_message, op)).to eq("simple string error")
    end

    it "returns string when error.errors is empty" do
      err = double("err", errors: [], to_s: "error with empty errors")
      op = double("op", error: err)
      expect(nx.send(:op_error_message, op)).to eq("error with empty errors")
    end

    it "includes HTTP status and message when present" do
      op = double("op", error: nil, http_error_status_code: 409, http_error_message: "Already exists")
      expect(nx.send(:op_error_message, op)).to eq("Already exists (HTTP 409)")
    end

    it "includes bare HTTP status when op has no http_error_message method" do
      op = double("op", error: nil, http_error_status_code: 500)
      expect(nx.send(:op_error_message, op)).to eq("HTTP 500")
    end

    it "returns nil when op has no error or HTTP error methods" do
      op = double("op")
      expect(nx.send(:op_error_message, op)).to be_nil
    end
  end

  describe "#op_error_code" do
    it "returns nil when error does not respond to :errors" do
      op = double("op", error: "simple string error")
      expect(nx.send(:op_error_code, op)).to be_nil
    end

    it "returns nil when errors is nil" do
      err = double("err", errors: nil)
      op = double("op", error: err)
      expect(nx.send(:op_error_code, op)).to be_nil
    end

    it "returns nil when errors is empty" do
      err = double("err", errors: [])
      op = double("op", error: err)
      expect(nx.send(:op_error_code, op)).to be_nil
    end
  end

  describe "#op_error?" do
    it "returns false when there is no structured or HTTP error" do
      op = double("op", error: nil, http_error_status_code: nil)
      expect(nx.send(:op_error?, op)).to be(false)
    end

    it "returns false when HTTP error code is zero" do
      op = double("op", error: nil, http_error_status_code: 0)
      expect(nx.send(:op_error?, op)).to be(false)
    end

    it "returns true when structured operation errors exist" do
      err = double("err", errors: [double("detail", code: "QUOTA_EXCEEDED")])
      op = double("op", error: err, http_error_status_code: nil)
      expect(nx.send(:op_error?, op)).to be(true)
    end

    it "returns true when only HTTP error exists" do
      op = double("op", error: nil, http_error_status_code: 403)
      expect(nx.send(:op_error?, op)).to be(true)
    end
  end
  # rubocop:enable RSpec/VerifiedDoubles
end
