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

    it "raises AlreadyExistsError for 'already exists' failures" do
      pvc = {"metadata" => {"name" => "test-pvc"}}
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(pvc)).and_return(["persistentvolumeclaims \"test-pvc\" already exists", failure_status])
      expect { client.create_pvc(pvc) }.to raise_error(AlreadyExistsError)
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
        {"metadata" => {"name" => "pv2"}, "spec" => {"csi" => {"volumeHandle" => "vol-456"}}},
      ]}
    end

    it "finds PV by volume ID or throws error" do
      expect(client).to receive(:run_kubectl).with("get", "pv", "-oyaml").and_return(YAML.dump(pv_list)).twice

      result = client.find_pv_by_volume_id("vol-456")
      expect(result["metadata"]["name"]).to eq("pv2")

      expect { client.find_pv_by_volume_id("vol-999") }.to raise_error(ObjectNotFoundError)
    end
  end

  describe "#find_retained_pv_for_pvc" do
    let(:success_status) { instance_double(Process::Status, success?: true) }
    let(:retained_pv) do
      {
        "metadata" => {
          "name" => "old-pv-123",
          "annotations" => {"csi.ubicloud.com/old-pvc-object" => "base64data"},
        },
        "spec" => {
          "persistentVolumeReclaimPolicy" => "Retain",
          "claimRef" => {"namespace" => "default", "name" => "test-pvc"},
        },
      }
    end

    it "returns the matching retained PV" do
      pv_list = {"items" => [retained_pv]}
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump(pv_list), success_status])

      result = client.find_retained_pv_for_pvc("default", "test-pvc")
      expect(result["metadata"]["name"]).to eq("old-pv-123")
    end

    it "returns nil when no PV has the old-pvc-object annotation" do
      pv_list = {"items" => [
        {"metadata" => {"name" => "pv1", "annotations" => {}}, "spec" => {"persistentVolumeReclaimPolicy" => "Retain", "claimRef" => {"namespace" => "default", "name" => "test-pvc"}}},
      ]}
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump(pv_list), success_status])

      expect(client.find_retained_pv_for_pvc("default", "test-pvc")).to be_nil
    end

    it "returns nil when PV has wrong claimRef" do
      pv = retained_pv.dup
      pv["spec"] = retained_pv["spec"].merge("claimRef" => {"namespace" => "other-ns", "name" => "other-pvc"})
      pv_list = {"items" => [pv]}
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump(pv_list), success_status])

      expect(client.find_retained_pv_for_pvc("default", "test-pvc")).to be_nil
    end

    it "returns nil when PV reclaim policy is not Retain" do
      pv = retained_pv.dup
      pv["spec"] = retained_pv["spec"].merge("persistentVolumeReclaimPolicy" => "Delete")
      pv_list = {"items" => [pv]}
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump(pv_list), success_status])

      expect(client.find_retained_pv_for_pvc("default", "test-pvc")).to be_nil
    end
  end

  describe "#get_nodeplugin_pods" do
    let(:pods_list) do
      {"items" => [
        {
          "metadata" => {"name" => "ubicsi-nodeplugin-abc"},
          "spec" => {"nodeName" => "worker-1"},
          "status" => {"phase" => "Running", "podIP" => "10.0.0.1"},
        },
        {
          "metadata" => {"name" => "ubicsi-nodeplugin-xyz"},
          "spec" => {"nodeName" => "worker-2"},
          "status" => {"phase" => "Running", "podIP" => "10.0.0.2"},
        },
        {
          "metadata" => {"name" => "ubicsi-nodeplugin-pending"},
          "spec" => {"nodeName" => "worker-3"},
          "status" => {"phase" => "Pending", "podIP" => nil},
        },
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
          "status" => {"phase" => "Running"},
        },
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
          "status" => {"phase" => "Running", "podIP" => "10.96.0.5"},
        },
        {
          "metadata" => {"name" => "coredns-xyz789"},
          "status" => {"phase" => "Running", "podIP" => "10.96.0.6"},
        },
        {
          "metadata" => {"name" => "coredns-pending"},
          "status" => {"phase" => "Pending", "podIP" => nil},
        },
      ]}
    end

    it "returns only running CoreDNS pods" do
      expect(client).to receive(:run_kubectl).with("-n", "kube-system", "get", "pods", "-l", "k8s-app=kube-dns", "-oyaml").and_return(YAML.dump(pods_list))

      expect(client.get_coredns_pods).to eq([{"name" => "coredns-abc123", "ip" => "10.96.0.5"}, {"name" => "coredns-xyz789", "ip" => "10.96.0.6"}])
    end
  end

  describe "#list_storage_classes_for_driver" do
    it "returns names of StorageClasses provisioned by our driver" do
      sc_list = {"items" => [
        {"metadata" => {"name" => "ubicloud-standard"}, "provisioner" => "csi.ubicloud.com"},
        {"metadata" => {"name" => "ubicloud-fast"}, "provisioner" => "csi.ubicloud.com"},
        {"metadata" => {"name" => "other"}, "provisioner" => "other.example.com"},
      ]}
      expect(client).to receive(:run_kubectl).with("get", "storageclasses", "-oyaml").and_return(YAML.dump(sc_list))
      expect(client.list_storage_classes_for_driver).to eq(["ubicloud-standard", "ubicloud-fast"])
    end

    it "returns an empty array when no StorageClasses match" do
      sc_list = {"items" => [{"metadata" => {"name" => "other"}, "provisioner" => "other.example.com"}]}
      expect(client).to receive(:run_kubectl).with("get", "storageclasses", "-oyaml").and_return(YAML.dump(sc_list))
      expect(client.list_storage_classes_for_driver).to eq([])
    end
  end

  describe "#list_csi_nodes_with_driver" do
    it "returns hostnames of nodes where our driver's node plugin is registered" do
      csinodes = {"items" => [
        {"metadata" => {"name" => "worker-1"}, "spec" => {"drivers" => [{"name" => "csi.ubicloud.com"}]}},
        {"metadata" => {"name" => "worker-2"}, "spec" => {"drivers" => [{"name" => "other.example.com"}, {"name" => "csi.ubicloud.com"}]}},
        {"metadata" => {"name" => "worker-3"}, "spec" => {"drivers" => [{"name" => "other.example.com"}]}},
        {"metadata" => {"name" => "worker-4"}, "spec" => {}},
      ]}
      expect(client).to receive(:run_kubectl).with("get", "csinodes", "-oyaml").and_return(YAML.dump(csinodes))
      expect(client.list_csi_nodes_with_driver).to eq(["worker-1", "worker-2"])
    end
  end

  describe "#list_csi_storage_capacities" do
    let(:sc_list) { {"items" => [{"metadata" => {"name" => "ubicloud-standard"}, "provisioner" => "csi.ubicloud.com"}]} }

    it "filters CSIStorageCapacity objects to those of our StorageClasses" do
      capacity_list = {"items" => [
        {"metadata" => {"name" => "csisc-a"}, "storageClassName" => "ubicloud-standard"},
        {"metadata" => {"name" => "csisc-b"}, "storageClassName" => "other-class"},
      ]}
      expect(client).to receive(:run_kubectl).with("get", "storageclasses", "-oyaml").and_return(YAML.dump(sc_list))
      expect(client).to receive(:run_kubectl).with("-n", "ubicsi", "get", "csistoragecapacities", "-oyaml").and_return(YAML.dump(capacity_list))

      result = client.list_csi_storage_capacities
      expect(result.map { |obj| obj["metadata"]["name"] }).to eq(["csisc-a"])
    end

    it "short-circuits to an empty list when no StorageClasses match our driver" do
      expect(client).to receive(:run_kubectl).with("get", "storageclasses", "-oyaml").and_return(YAML.dump({"items" => []}))
      expect(client).not_to receive(:run_kubectl)
      expect(client.list_csi_storage_capacities).to eq([])
    end
  end

  describe "#create_csi_storage_capacity" do
    let(:base_obj) do
      {
        "apiVersion" => "storage.k8s.io/v1",
        "kind" => "CSIStorageCapacity",
        "metadata" => {"name" => "csisc-w1-standard", "namespace" => "ubicsi"},
        "nodeTopology" => {"matchLabels" => {"kubernetes.io/hostname" => "worker-1"}},
        "storageClassName" => "ubicloud-standard",
        "capacity" => "1073741824",
        "maximumVolumeSize" => "10737418240",
      }
    end

    it "creates the object with the right shape" do
      expect(client).to receive(:run_kubectl).with("create", "-f", "-", yaml_data: base_obj)
      client.create_csi_storage_capacity(
        name: "csisc-w1-standard",
        hostname: "worker-1",
        storage_class: "ubicloud-standard",
        capacity_bytes: 1_073_741_824,
        max_volume_size: 10_737_418_240,
      )
    end

    it "stamps an ownerReference when provided" do
      owner_ref = {"apiVersion" => "apps/v1", "kind" => "Deployment", "name" => "ubicsi-provisioner", "uid" => "deploy-uid", "controller" => true}
      expected = base_obj.merge("metadata" => base_obj["metadata"].merge("ownerReferences" => [owner_ref]))
      expect(client).to receive(:run_kubectl).with("create", "-f", "-", yaml_data: expected)
      client.create_csi_storage_capacity(
        name: "csisc-w1-standard",
        hostname: "worker-1",
        storage_class: "ubicloud-standard",
        capacity_bytes: 1_073_741_824,
        max_volume_size: 10_737_418_240,
        owner_ref:,
      )
    end
  end

  describe "#patch_csi_storage_capacity" do
    it "merge-patches capacity and maximumVolumeSize" do
      patch = {capacity: "1073741824", maximumVolumeSize: "10737418240"}.to_json
      expect(client).to receive(:run_kubectl).with("-n", "ubicsi", "patch", "csistoragecapacity", "csisc-x", "--type=merge", "-p", patch)
      client.patch_csi_storage_capacity(name: "csisc-x", capacity_bytes: 1_073_741_824, max_volume_size: 10_737_418_240)
    end
  end

  describe "#delete_csi_storage_capacity" do
    it "deletes the object with --ignore-not-found" do
      expect(client).to receive(:run_kubectl).with("-n", "ubicsi", "delete", "csistoragecapacity", "csisc-x", "--ignore-not-found=true")
      client.delete_csi_storage_capacity(name: "csisc-x")
    end
  end

  describe "#get_provisioner_deployment_owner_ref" do
    it "returns an ownerReference pointing at the controller Deployment" do
      deploy = {
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => {"name" => "ubicsi-provisioner", "uid" => "deploy-uid-123"},
      }
      expect(client).to receive(:run_kubectl).with("-n", "ubicsi", "get", "deployment", "ubicsi-provisioner", "-oyaml").and_return(YAML.dump(deploy))
      expect(client.get_provisioner_deployment_owner_ref).to eq({
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "name" => "ubicsi-provisioner",
        "uid" => "deploy-uid-123",
        "controller" => true,
      })
    end
  end
end
