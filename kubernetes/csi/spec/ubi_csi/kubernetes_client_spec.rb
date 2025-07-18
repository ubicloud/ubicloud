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

    context "with req_id set" do
      it "logs the command when req_id is nil" do
        expect(client.instance_variable_get(:@logger)).to receive(:info).with(/kubectl get pods/)
        allow(client).to receive(:run_cmd).and_return(["success", success_status])
        client.run_kubectl(*args)
      end

      it "does not log when req_id is set" do
        allow(client_with_req_id).to receive(:run_cmd).and_return(["success", success_status])
        # Should not raise any errors about missing logger
        expect { client_with_req_id.run_kubectl(*args) }.not_to raise_error
      end
    end
  end

  describe "#get_node" do
    let(:node_yaml) { { "metadata" => { "name" => "test-node" } } }

    it "gets node information" do
      expect(client).to receive(:run_kubectl).with("get", "node", "test-node", "-oyaml").and_return(YAML.dump(node_yaml))
      result = client.get_node("test-node")
      expect(result["metadata"]["name"]).to eq("test-node")
    end
  end

  describe "#get_node_ip" do
    let(:node_yaml) do
      {
        "status" => {
          "addresses" => [
            { "type" => "InternalIP", "address" => "10.0.0.1" }
          ]
        }
      }
    end

    it "extracts node IP address" do
      allow(client).to receive(:get_node).with("test-node").and_return(node_yaml)
      result = client.get_node_ip("test-node")
      expect(result).to eq("10.0.0.1")
    end
  end

  describe "#get_pv" do
    let(:pv_yaml) { { "metadata" => { "name" => "test-pv" } } }

    it "gets persistent volume information" do
      expect(client).to receive(:run_kubectl).with("get", "pv", "test-pv", "-oyaml").and_return(YAML.dump(pv_yaml))
      result = client.get_pv("test-pv")
      expect(result["metadata"]["name"]).to eq("test-pv")
    end
  end

  describe "#extract_node_from_pv" do
    let(:pv_data) do
      {
        "spec" => {
          "nodeAffinity" => {
            "required" => {
              "nodeSelectorTerms" => [
                {
                  "matchExpressions" => [
                    {
                      "values" => ["worker-node-1"]
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    end

    it "extracts node name from PV node affinity" do
      result = client.extract_node_from_pv(pv_data)
      expect(result).to eq("worker-node-1")
    end
  end

  describe "#create_pv" do
    let(:pv_data) { { "metadata" => { "name" => "new-pv" } } }

    it "creates persistent volume" do
      expect(client).to receive(:run_kubectl).with("create", "-f", "-", stdin_data: YAML.dump(pv_data))
      client.create_pv(pv_data)
    end
  end

  describe "#update_pv" do
    let(:pv_data) { { "metadata" => { "name" => "updated-pv" } } }

    it "updates persistent volume" do
      expect(client).to receive(:run_kubectl).with("apply", "-f", "-", stdin_data: YAML.dump(pv_data))
      client.update_pv(pv_data)
    end
  end

  describe "#get_pvc" do
    let(:pvc_yaml) { { "metadata" => { "name" => "test-pvc" } } }

    it "gets persistent volume claim information" do
      expect(client).to receive(:run_kubectl).with("-n", "test-namespace", "get", "pvc", "test-pvc", "-oyaml").and_return(YAML.dump(pvc_yaml))
      result = client.get_pvc("test-namespace", "test-pvc")
      expect(result["metadata"]["name"]).to eq("test-pvc")
    end
  end

  describe "#create_pvc" do
    let(:pvc_data) { { "metadata" => { "name" => "new-pvc" } } }

    it "creates persistent volume claim" do
      expect(client).to receive(:run_kubectl).with("create", "-f", "-", stdin_data: YAML.dump(pvc_data))
      client.create_pvc(pvc_data)
    end
  end

  describe "#update_pvc" do
    let(:pvc_data) { { "metadata" => { "name" => "updated-pvc" } } }

    it "updates persistent volume claim" do
      expect(client).to receive(:run_kubectl).with("apply", "-f", "-", stdin_data: YAML.dump(pvc_data))
      client.update_pvc(pvc_data)
    end
  end

  describe "#delete_pvc" do
    it "deletes persistent volume claim" do
      expect(client).to receive(:run_kubectl).with("-n", "test-namespace", "delete", "pvc", "test-pvc", "--wait=false", "--ignore-not-found=true")
      client.delete_pvc("test-namespace", "test-pvc")
    end
  end

  describe "#node_schedulable?" do
    context "when node is schedulable" do
      let(:node_data) { { "spec" => {} } }

      it "returns true" do
        allow(client).to receive(:get_node).with("test-node").and_return(node_data)
        result = client.node_schedulable?("test-node")
        expect(result).to be true
      end
    end

    context "when node is unschedulable" do
      let(:node_data) { { "spec" => { "unschedulable" => true } } }

      it "returns false" do
        allow(client).to receive(:get_node).with("test-node").and_return(node_data)
        result = client.node_schedulable?("test-node")
        expect(result).to be false
      end
    end

    context "when node spec is nil" do
      let(:node_data) { { "spec" => nil } }

      it "returns true" do
        allow(client).to receive(:get_node).with("test-node").and_return(node_data)
        result = client.node_schedulable?("test-node")
        expect(result).to be true
      end
    end
  end

  describe "#find_pv_by_volume_id" do
    let(:pv_list) do
      {
        "items" => [
          {
            "metadata" => { "name" => "pv1" },
            "spec" => { "csi" => { "volumeHandle" => "vol-123" } }
          },
          {
            "metadata" => { "name" => "pv2" },
            "spec" => { "csi" => { "volumeHandle" => "vol-456" } }
          }
        ]
      }
    end

    it "finds PV by volume ID" do
      expect(client).to receive(:run_kubectl).with("get", "pv", "-oyaml").and_return(YAML.dump(pv_list))
      result = client.find_pv_by_volume_id("vol-456")
      expect(result["metadata"]["name"]).to eq("pv2")
    end

    it "returns nil when volume ID not found" do
      expect(client).to receive(:run_kubectl).with("get", "pv", "-oyaml").and_return(YAML.dump(pv_list))
      result = client.find_pv_by_volume_id("vol-999")
      expect(result).to be_nil
    end
  end
end

