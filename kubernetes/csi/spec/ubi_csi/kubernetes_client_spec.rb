# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Csi::KubernetesClient do
  let(:client) { described_class.new }
  let(:client_with_req_id) { described_class.new(req_id: "test-req-id") }

  describe "#initialize" do
    context "without req_id" do
      it "initializes with a logger" do
        expect(client.instance_variable_get(:@logger)).to be_a(Logger)
      end

      it "sets req_id to nil" do
        expect(client.instance_variable_get(:@req_id)).to be_nil
      end
    end

    context "with req_id" do
      it "sets the req_id" do
        expect(client_with_req_id.instance_variable_get(:@req_id)).to eq("test-req-id")
      end

      it "does not initialize logger" do
        expect(client_with_req_id.instance_variable_get(:@logger)).to be_nil
      end
    end
  end

  describe "#run_cmd" do
    let(:cmd) { ["echo", "test"] }
    let(:status) { instance_double("Process::Status", success?: true) }

    it "executes command using Open3.capture2e" do
      expect(Open3).to receive(:capture2e).with(*cmd).and_return(["output", status])
      result = client.run_cmd(*cmd)
      expect(result).to eq(["output", status])
    end

    it "passes options to Open3.capture2e" do
      options = { stdin_data: "test input" }
      expect(Open3).to receive(:capture2e).with(*cmd, **options).and_return(["output", status])
      client.run_cmd(*cmd, **options)
    end
  end

  describe "#run_kubectl" do
    let(:args) { ["get", "pods"] }
    let(:success_status) { instance_double("Process::Status", success?: true) }
    let(:failure_status) { instance_double("Process::Status", success?: false) }

    context "when command succeeds" do
      before do
        allow(client).to receive(:run_cmd).and_return(["success output", success_status])
      end

      it "executes kubectl command" do
        expect(client).to receive(:run_cmd).with("kubectl", *args, stdin_data: nil)
        client.run_kubectl(*args)
      end

      it "returns the output" do
        result = client.run_kubectl(*args)
        expect(result).to eq("success output")
      end
    end

    context "when command fails with 'not found'" do
      before do
        allow(client).to receive(:run_cmd).and_return(["resource not found", failure_status])
      end

      it "raises ObjectNotFoundError" do
        expect { client.run_kubectl(*args) }.to raise_error(ObjectNotFoundError, "resource not found")
      end
    end

    context "when command fails with other error" do
      before do
        allow(client).to receive(:run_cmd).and_return(["other error", failure_status])
      end

      it "raises generic error" do
        expect { client.run_kubectl(*args) }.to raise_error(/Command failed: kubectl get pods/)
      end
    end

    context "with stdin_data" do
      let(:stdin_data) { "test input" }

      before do
        allow(client).to receive(:run_cmd).and_return(["success", success_status])
      end

      it "passes stdin_data to run_cmd" do
        expect(client).to receive(:run_cmd).with("kubectl", *args, stdin_data: stdin_data)
        client.run_kubectl(*args, stdin_data: stdin_data)
      end
    end
  end
end

