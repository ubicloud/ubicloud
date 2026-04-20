# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../spec_helper"

RSpec.describe GcpLro do
  let(:project) { Project.create(name: "test-gcp-lro") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }
  let(:credential) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }
  let(:private_subnet) {
    credential
    PrivateSubnet.create(name: "ps", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting", project_id: project.id, firewall_priority: 1000)
  }
  let(:strand) { Strand.create_with_id(private_subnet, prog: "Vnet::Gcp::SubnetNexus", label: "start") }
  # google-cloud-compute-v1 does not expose a test fixture stub equivalent to
  # AWS SDK's stub_responses, so operations clients are stubbed individually
  # on the real LocationCredentialGcp row.
  let(:zone_ops_client) { instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client) }
  let(:region_ops_client) { instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client) }
  let(:global_ops_client) { instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client) }

  let(:nx) { Prog::Vnet::Gcp::SubnetNexus.new(strand) }

  before do
    allow(nx.send(:credential)).to receive_messages(
      zone_operations_client: zone_ops_client,
      region_operations_client: region_ops_client,
      global_operations_client: global_ops_client,
    )
  end

  describe "#poll_gcp_op" do
    it "raises for unknown scope" do
      refresh_frame(nx, new_values: {"my_lro" => {"name" => "op-123", "scope" => "invalid", "scope_value" => nil}})

      expect { nx.send(:poll_gcp_op, "my_lro") }.to raise_error(RuntimeError, /Unknown GCP operation scope: invalid/)
    end

    it "polls a named LRO slot" do
      refresh_frame(nx, new_values: {"my_lro" => {"name" => "op-named", "scope" => "global", "scope_value" => nil}})

      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get)
        .with(project: "test-gcp-project", operation: "op-named")
        .and_return(op)
      expect(nx.send(:poll_gcp_op, "my_lro")).to eq(op)
    end
  end

  def build_op(error: nil, http_error_status_code: 0, http_error_message: "")
    Google::Cloud::Compute::V1::Operation.new(
      error:,
      http_error_status_code:,
      http_error_message:,
    )
  end

  def build_error(*details)
    Google::Cloud::Compute::V1::Error.new(
      errors: details.map { |d| Google::Cloud::Compute::V1::Errors.new(code: d[:code], message: d.fetch(:message, "")) },
    )
  end

  describe "#op_error_message" do
    it "joins structured error details" do
      op = build_op(error: build_error({code: "QUOTA_EXCEEDED", message: "quota"}))
      expect(nx.send(:op_error_message, op)).to eq("quota (code: QUOTA_EXCEEDED)")
    end

    it "returns stringified error when structured details are empty" do
      op = build_op(error: build_error)
      expect(nx.send(:op_error_message, op)).to eq(op.error.to_s)
    end

    it "includes HTTP status and message when present" do
      op = build_op(http_error_status_code: 409, http_error_message: "Already exists")
      expect(nx.send(:op_error_message, op)).to eq("Already exists (HTTP 409)")
    end

    it "includes bare HTTP status when http_error_message is empty" do
      op = build_op(http_error_status_code: 500)
      expect(nx.send(:op_error_message, op)).to eq("HTTP 500")
    end

    it "returns nil when no structured or HTTP error is set" do
      expect(nx.send(:op_error_message, build_op)).to be_nil
    end
  end

  describe "#op_error_code" do
    it "returns the first detail code when present" do
      op = build_op(error: build_error({code: "QUOTA_EXCEEDED"}, {code: "OTHER"}))
      expect(nx.send(:op_error_code, op)).to eq("QUOTA_EXCEEDED")
    end

    it "returns nil when error is unset" do
      expect(nx.send(:op_error_code, build_op)).to be_nil
    end

    it "returns nil when errors list is empty" do
      expect(nx.send(:op_error_code, build_op(error: build_error))).to be_nil
    end
  end

  describe "#op_error?" do
    it "returns false when there is no structured or HTTP error" do
      expect(nx.send(:op_error?, build_op)).to be(false)
    end

    it "returns true when structured operation errors exist" do
      op = build_op(error: build_error({code: "QUOTA_EXCEEDED"}))
      expect(nx.send(:op_error?, op)).to be(true)
    end

    it "returns true when only HTTP error exists" do
      expect(nx.send(:op_error?, build_op(http_error_status_code: 403))).to be(true)
    end
  end

  describe "#save_gcp_op and #clear_gcp_op" do
    it "saves and clears a named LRO slot" do
      nx.save_gcp_op(name: "my_lro", op_name: "op-named", scope: "region", scope_value: "us-central1")
      strand.reload
      expect(strand.stack.first["my_lro"]).to eq({"name" => "op-named", "scope" => "region", "scope_value" => "us-central1"})

      refresh_frame(nx)
      nx.clear_gcp_op("my_lro")
      strand.reload
      expect(strand.stack.first["my_lro"]).to be_nil
    end
  end

  describe "#poll_and_clear_gcp_op" do
    before do
      refresh_frame(nx, new_values: {"gcp_op" => {"name" => "op-abc", "scope" => "global", "scope_value" => nil}})
    end

    it "naps when the operation is still running and does not yield" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      yielded = false
      expect { nx.poll_and_clear_gcp_op("gcp_op") { yielded = true } }.to raise_error(Prog::Base::Nap)
      expect(yielded).to be(false)
      expect(strand.reload.stack.first["gcp_op"]).to eq({"name" => "op-abc", "scope" => "global", "scope_value" => nil})
    end

    it "clears the op and does not yield when the operation succeeds" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).and_return(op)
      yielded = false
      result = nx.poll_and_clear_gcp_op("gcp_op") { yielded = true }
      expect(yielded).to be(false)
      expect(result).to eq(op)
      expect(strand.reload.stack.first["gcp_op"]).to be_nil
    end

    it "yields the errored op then clears the op when the block falls through" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "transient")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      yielded_op = nil
      result = nx.poll_and_clear_gcp_op("gcp_op") { |o| yielded_op = o }
      expect(yielded_op).to eq(op)
      expect(result).to eq(op)
      expect(strand.reload.stack.first["gcp_op"]).to be_nil
    end

    it "does not clear the op when the recovery block raises" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "FATAL", message: "fatal")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect {
        nx.poll_and_clear_gcp_op("gcp_op") { |_| raise "recovery failed" }
      }.to raise_error(RuntimeError, "recovery failed")
      expect(strand.reload.stack.first["gcp_op"]).to eq({"name" => "op-abc", "scope" => "global", "scope_value" => nil})
    end

    it "works with a named LRO slot" do
      refresh_frame(nx, new_values: {"my_lro" => {"name" => "op-named", "scope" => "global", "scope_value" => nil}})

      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get)
        .with(project: "test-gcp-project", operation: "op-named")
        .and_return(op)
      result = nx.poll_and_clear_gcp_op("my_lro") {}
      expect(result).to eq(op)
      expect(strand.reload.stack.first["my_lro"]).to be_nil
    end
  end
end
