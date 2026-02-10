# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::KubernetesClient do
  let(:logger) { Logger.new(File::NULL) }
  let(:client) { described_class.new(req_id: "test-req-id", logger:) }

  describe "#initialize" do
    it "initializes correctly with req_id" do
      expect(client.instance_variable_get(:@logger)).to be_a(Logger)
      expect(client.instance_variable_get(:@req_id)).to eq("test-req-id")
    end
  end

  describe "#run_cmd" do
    let(:cmd) { ["echo", "test"] }
    let(:status) { instance_double(Process::Status, success?: true) }

    it "executes command using Open3.capture2e" do
      expect(Open3).to receive(:capture2e).with(*cmd).and_return(["output", status])
      result = client.run_cmd(*cmd, req_id: "req-id")
      expect(result).to eq(["output", status])
    end

    it "passes options to Open3.capture2e" do
      options = {stdin_data: "test input"}
      expect(Open3).to receive(:capture2e).with(*cmd, **options).and_return(["output", status])
      client.run_cmd(*cmd, req_id: "req-id", **options)
    end
  end

  describe "#run_kubectl" do
    let(:args) { ["get", "pods"] }
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:failure_status) { instance_double(Process::Status, success?: false) }

    it "executes kubectl command and returns output on success" do
      expect(client).to receive(:run_cmd).and_return(["success output", success_status]).at_least(:once)
      result = client.run_kubectl(*args)
      expect(result).to eq("success output")
    end

    it "raises ObjectNotFoundError for 'not found' failures" do
      expect(client).to receive(:run_cmd).and_return(["resource not found", failure_status]).at_least(:once)
      expect { client.run_kubectl(*args) }.to raise_error(ObjectNotFoundError, "resource not found")
    end

    it "raises generic error for other failures" do
      expect(client).to receive(:run_cmd).and_return(["other error", failure_status]).at_least(:once)
      expect { client.run_kubectl(*args) }.to raise_error(/Command failed: kubectl get pods/)
    end

    it "passes stdin_data to run_cmd" do
      expect(client).to receive(:run_cmd).and_return(["success", success_status]).at_least(:once)
      client.run_kubectl(*args, yaml_data: "test input")
    end

    it "does not log when req_id is set" do
      expect(client).to receive(:run_cmd).and_return(["success", success_status]).at_least(:once)
      expect { client.run_kubectl(*args) }.not_to raise_error
    end
  end

  describe "resource operations" do
    let(:node_yaml) { {"metadata" => {"name" => "test-node"}} }
    let(:pv_yaml) { {"metadata" => {"name" => "test-pv"}} }
    let(:pvc_yaml) { {"metadata" => {"name" => "test-pvc"}} }

    it "gets node information" do
      expect(client).to receive(:run_kubectl).with("get", "node", "test-node", "-oyaml").and_return(YAML.dump(node_yaml))
      result = client.get_node("test-node")
      expect(result["metadata"]["name"]).to eq("test-node")
    end

    it "gets node IP address" do
      node_with_ip = {"status" => {"addresses" => [{"type" => "InternalIP", "address" => "10.0.0.1"}]}}
      expect(client).to receive(:get_node).with("test-node").and_return(node_with_ip).at_least(:once)
      result = client.get_node_ip("test-node")
      expect(result).to eq("10.0.0.1")
    end

    it "gets PV information" do
      expect(client).to receive(:run_kubectl).with("get", "pv", "test-pv", "-oyaml").and_return(YAML.dump(pv_yaml))
      result = client.get_pv("test-pv")
      expect(result["metadata"]["name"]).to eq("test-pv")
    end

    it "extracts node from PV node affinity" do
      pv_data = {"spec" => {"nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["worker-node-1"]}]}]}}}}
      result = client.extract_node_from_pv(pv_data)
      expect(result).to eq("worker-node-1")
    end

    it "creates and updates PVs" do
      expect(client).to receive(:run_kubectl).with("create", "-f", "-", yaml_data: pv_yaml)
      client.create_pv(pv_yaml)

      expect(client).to receive(:run_kubectl).with("apply", "-f", "-", yaml_data: pv_yaml)
      client.update_pv(pv_yaml)
    end

    it "gets PVC information" do
      expect(client).to receive(:run_kubectl).with("-n", "test-namespace", "get", "pvc", "test-pvc", "-oyaml").and_return(pvc_yaml.to_yaml)
      result = client.get_pvc("test-namespace", "test-pvc")
      expect(result["metadata"]["name"]).to eq("test-pvc")
    end

    it "creates, updates, and deletes PVCs" do
      expect(client).to receive(:run_kubectl).with("create", "-f", "-", yaml_data: pvc_yaml)
      client.create_pvc(pvc_yaml)

      expect(client).to receive(:run_kubectl).with("apply", "-f", "-", yaml_data: pvc_yaml)
      client.update_pvc(pvc_yaml)

      expect(client).to receive(:run_kubectl).with("-n", "test-namespace", "delete", "pvc", "test-pvc", "--wait=false", "--ignore-not-found=true")
      client.delete_pvc("test-namespace", "test-pvc")
    end

    it "does not try to remove finalizers when pvc does not exist" do
      namespace, name = "namespace", "pvc-name"
      expect(client).to receive(:get_pvc).with(namespace, name).and_raise(ObjectNotFoundError)
      expect(client).not_to receive(:run_kubectl)
      client.remove_pvc_finalizers(namespace, name)
    end

    it "removes finalizers when pvc exists" do
      namespace, name = "namespace", "pvc-name"
      expect(client).to receive(:get_pvc).with(namespace, name).and_return({})
      expect(client).to receive(:run_kubectl).with("-n", namespace, "patch", "pvc", name, "--type=merge", "-p", "{\"metadata\":{\"finalizers\":null}}")
      client.remove_pvc_finalizers(namespace, name)
    end
  end

  describe "#patch_resource" do
    it "patches a pvc correctly with the given namespace" do
      resource, name, namespace, annotation_key, annotation_value = "pvc", "name", "default", "foo", "bar"
      expect(client).to receive(:run_kubectl).with("-n", namespace, "patch", "pvc", name, "--type=merge", "-p", "{\"metadata\":{\"annotations\":{\"#{annotation_key}\":\"#{annotation_value}\"}}}")
      client.patch_resource(resource, name, annotation_key, annotation_value, namespace:)
    end

    it "patches a pv correctly which requires no namespace" do
      resource, name, annotation_key, annotation_value = "pv", "name", "foo", "bar"
      expect(client).to receive(:run_kubectl).with("patch", "pv", name, "--type=merge", "-p", "{\"metadata\":{\"annotations\":{\"#{annotation_key}\":\"#{annotation_value}\"}}}")
      client.patch_resource(resource, name, annotation_key, annotation_value)
    end
  end

  describe "#remove_pvc_annotation" do
    it "removes the given pvc annotations" do
      namespace, name, annotation_key = "namespace", "name", "key"
      expect(client).to receive(:run_kubectl).with("-n", namespace, "patch", "pvc", name, "--type=merge", "-p", "{\"metadata\":{\"annotations\":{\"#{annotation_key}\":null}}}")
      client.remove_pvc_annotation(namespace, name, annotation_key)
    end
  end

  describe "#node_schedulable?" do
    it "returns correct schedulability status" do
      expect(client).to receive(:get_node).with("test-node").and_return({"spec" => {}})
      expect(client.node_schedulable?("test-node")).to be true

      expect(client).to receive(:get_node).with("test-node").and_return({"spec" => {"unschedulable" => true}})
      expect(client.node_schedulable?("test-node")).to be false

      expect(client).to receive(:get_node).with("test-node").and_return({"spec" => nil})
      expect(client.node_schedulable?("test-node")).to be true
    end
  end

  describe "#find_pv_by_volume_id" do
    let(:pv_list) do
      {"items" => [
        {"metadata" => {"name" => "pv1"}, "spec" => {"csi" => {"volumeHandle" => "vol-123"}}},
        {"metadata" => {"name" => "pv2"}, "spec" => {"csi" => {"volumeHandle" => "vol-456"}}}
      ]}
    end

    it "finds PV by volume ID or throws error" do
      expect(client).to receive(:run_kubectl).with("get", "pv", "-oyaml").and_return(YAML.dump(pv_list)).twice

      result = client.find_pv_by_volume_id("vol-456")
      expect(result["metadata"]["name"]).to eq("pv2")

      expect { client.find_pv_by_volume_id("vol-999") }.to raise_error(ObjectNotFoundError)
    end
  end

  describe "#get_nodeplugin_pods" do
    let(:pods_list) do
      {"items" => [
        {
          "metadata" => {"name" => "ubicsi-nodeplugin-abc"},
          "spec" => {"nodeName" => "worker-1"},
          "status" => {"phase" => "Running", "podIP" => "10.0.0.1"}
        },
        {
          "metadata" => {"name" => "ubicsi-nodeplugin-xyz"},
          "spec" => {"nodeName" => "worker-2"},
          "status" => {"phase" => "Running", "podIP" => "10.0.0.2"}
        },
        {
          "metadata" => {"name" => "ubicsi-nodeplugin-pending"},
          "spec" => {"nodeName" => "worker-3"},
          "status" => {"phase" => "Pending", "podIP" => nil}
        }
      ]}
    end

    it "returns only running nodeplugin pods" do
      expect(client).to receive(:run_kubectl).with("-n", "ubicsi", "get", "pods", "-l", "app=ubicsi,component=nodeplugin", "-oyaml").and_return(YAML.dump(pods_list))

      result = client.get_nodeplugin_pods

      expect(result.size).to eq(2)
      expect(result).to include({"name" => "ubicsi-nodeplugin-abc", "ip" => "10.0.0.1", "node" => "worker-1"})
      expect(result).to include({"name" => "ubicsi-nodeplugin-xyz", "ip" => "10.0.0.2", "node" => "worker-2"})
      expect(result).not_to include(hash_including("name" => "ubicsi-nodeplugin-pending"))
    end

    it "handles pods with missing fields" do
      pods_with_missing_fields = {"items" => [
        {
          "metadata" => {},
          "spec" => {},
          "status" => {"phase" => "Running"}
        }
      ]}
      expect(client).to receive(:run_kubectl).with("-n", "ubicsi", "get", "pods", "-l", "app=ubicsi,component=nodeplugin", "-oyaml").and_return(YAML.dump(pods_with_missing_fields))

      result = client.get_nodeplugin_pods

      expect(result.size).to eq(1)
      expect(result.first["name"]).to be_nil
      expect(result.first["ip"]).to be_nil
      expect(result.first["node"]).to be_nil
    end
  end

  describe "#get_coredns_pods" do
    let(:pods_list) do
      {"items" => [
        {
          "metadata" => {"name" => "coredns-abc123"},
          "status" => {"phase" => "Running", "podIP" => "10.96.0.5"}
        },
        {
          "metadata" => {"name" => "coredns-xyz789"},
          "status" => {"phase" => "Running", "podIP" => "10.96.0.6"}
        },
        {
          "metadata" => {"name" => "coredns-pending"},
          "status" => {"phase" => "Pending", "podIP" => nil}
        }
      ]}
    end

    it "returns only running CoreDNS pods" do
      expect(client).to receive(:run_kubectl).with("-n", "kube-system", "get", "pods", "-l", "k8s-app=kube-dns", "-oyaml").and_return(YAML.dump(pods_list))

      expect(client.get_coredns_pods).to eq([{"name" => "coredns-abc123", "ip" => "10.96.0.5"}, {"name" => "coredns-xyz789", "ip" => "10.96.0.6"}])
    end
  end
end
