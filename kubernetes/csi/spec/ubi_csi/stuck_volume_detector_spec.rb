# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::StuckVolumeDetector do
  let(:logger) { Logger.new(File::NULL) }
  let(:detector) { described_class.new(logger:) }
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failed_status) { instance_double(Process::Status, success?: false) }

  after { detector.shutdown! }

  describe "#shutdown!" do
    it "sets shutdown flag, closes queue, and joins thread" do
      expect(detector).to receive(:spawn_check_thread)

      detector.start
      detector.shutdown!

      expect(detector.instance_variable_get(:@shutdown)).to be(true)
      expect(detector.instance_variable_get(:@queue)).to be_closed
    end

    it "handles nil thread gracefully" do
      detector.shutdown!

      expect(detector.instance_variable_get(:@shutdown)).to be(true)
      expect(detector.instance_variable_get(:@queue)).to be_closed
    end
  end

  describe "#spawn_check_thread" do
    it "runs check_stuck_volumes in a thread" do
      sync = Queue.new
      expect(detector).to receive(:check_stuck_volumes) { sync.push(true) }

      detector.spawn_check_thread
      expect(sync.pop(timeout: 1)).to be true
      detector.shutdown!
    end
  end

  describe "#check_stuck_volumes" do
    before do
      allow(Csi::KubernetesClient).to receive(:new).and_call_original
    end

    it "skips PVCs without old-pv-name annotation" do
      pvc = {"metadata" => {"annotations" => {}}, "spec" => {"volumeName" => "pvc-123"}}
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pvc]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => []}), success_status])
      expect(detector).not_to receive(:recover_stuck_pvc)

      detector.check_stuck_volumes
    end

    it "skips PVCs without bound PV" do
      pvc = {
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}},
        "spec" => {},
      }
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pvc]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => []}), success_status])
      expect(detector).not_to receive(:recover_stuck_pvc)

      detector.check_stuck_volumes
    end

    it "skips PVCs bound to PVs on schedulable nodes" do
      pvc = {
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}},
        "spec" => {"volumeName" => "pvc-yyy"},
      }
      pv = {
        "metadata" => {"name" => "pvc-yyy"},
        "spec" => {
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["worker-1"]}]}]}},
        },
      }
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pvc]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pv]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([YAML.dump({"spec" => {}}), success_status])
      expect(detector).not_to receive(:recover_stuck_pvc)

      detector.check_stuck_volumes
    end

    it "detects and recovers PVC on cordoned node" do
      pvc = {
        "metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}},
        "spec" => {"volumeName" => "pvc-yyy"},
      }
      pv = {
        "metadata" => {"name" => "pvc-yyy"},
        "spec" => {
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["worker-1"]}]}]}},
        },
      }
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pvc]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pv]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([YAML.dump({"spec" => {"unschedulable" => true}}), success_status])
      expect(detector).to receive(:recover_stuck_pvc)

      detector.check_stuck_volumes
    end

    it "skips PVCs whose bound PV is not found" do
      pvc = {
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}},
        "spec" => {"volumeName" => "pvc-missing"},
      }
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pvc]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => []}), success_status])
      expect(detector).not_to receive(:recover_stuck_pvc)

      detector.check_stuck_volumes
    end

    it "skips PVCs whose bound PV has no node affinity" do
      pvc = {
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}},
        "spec" => {"volumeName" => "pvc-yyy"},
      }
      pv = {"metadata" => {"name" => "pvc-yyy"}, "spec" => {}}
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pvc]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pv]}), success_status])
      expect(detector).not_to receive(:recover_stuck_pvc)

      detector.check_stuck_volumes
    end

    it "handles API errors gracefully" do
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return(["API error", failed_status])

      detector.check_stuck_volumes
    end

    it "handles per-PVC errors without stopping iteration" do
      pvc1 = {
        "metadata" => {"namespace" => "ns1", "name" => "pvc1", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}},
        "spec" => {"volumeName" => "pvc-yyy"},
      }
      pvc2 = {
        "metadata" => {"namespace" => "ns2", "name" => "pvc2", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-aaa"}},
        "spec" => {"volumeName" => "pvc-bbb"},
      }
      pv1 = {
        "metadata" => {"name" => "pvc-yyy"},
        "spec" => {"nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["worker-1"]}]}]}}},
      }
      pv2 = {
        "metadata" => {"name" => "pvc-bbb"},
        "spec" => {"nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["worker-2"]}]}]}}},
      }
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pvc", "--all-namespaces", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pvc1, pvc2]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => [pv1, pv2]}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([YAML.dump({"spec" => {"unschedulable" => true}}), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-2", "-oyaml", stdin_data: nil).and_return([YAML.dump({"spec" => {"unschedulable" => true}}), success_status])
      expect(detector).to receive(:recover_stuck_pvc).ordered.and_raise(StandardError.new("recovery failed"))
      expect(detector).to receive(:recover_stuck_pvc).ordered

      detector.check_stuck_volumes
    end
  end

  describe "#recover_stuck_pvc" do
    let(:real_client) { Csi::KubernetesClient.new(req_id: "test-req-id", logger:) }
    let(:source_pv) { {"metadata" => {"name" => "pvc-xxx", "annotations" => {}}} }
    let(:intermediate_pv) do
      {
        "metadata" => {"name" => "pvc-yyy"},
        "spec" => {"persistentVolumeReclaimPolicy" => "Delete"},
      }
    end
    let(:pvc) do
      {
        "metadata" => {
          "namespace" => "default",
          "name" => "data-pvc",
          "uid" => "yyy",
          "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"},
          "resourceVersion" => "12345",
        },
        "spec" => {"volumeName" => "pvc-yyy", "accessModes" => ["ReadWriteOnce"]},
        "status" => {"phase" => "Bound"},
      }
    end

    let(:remove_finalizer_patch) { {"metadata" => {"finalizers" => nil}}.to_json }

    it "recovers stuck PVC by deleting and recreating it" do
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "get", "pvc", "data-pvc", "-oyaml", stdin_data: nil).and_return([YAML.dump(pvc), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", remove_finalizer_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "delete", "pvc", "data-pvc", "--wait=false", "--ignore-not-found=true", stdin_data: nil).and_return(["deleted", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(trimmed_pvc)).and_return(["created", success_status])

      detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx")
    end

    it "rolls back intermediate PV reclaim policy to Delete" do
      intermediate_pv["spec"]["persistentVolumeReclaimPolicy"] = "Retain"
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "delete", "pvc", "data-pvc", "--wait=false", "--ignore-not-found=true", stdin_data: nil).and_return(["deleted", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "get", "pvc", "data-pvc", "-oyaml", stdin_data: nil).and_return([YAML.dump(pvc), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", remove_finalizer_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(trimmed_pvc)).and_return(["created", success_status])
      applied_pv = {"metadata" => {"name" => "pvc-yyy"}, "spec" => {"persistentVolumeReclaimPolicy" => "Delete"}}
      expect(Open3).to receive(:capture2e).with("kubectl", "apply", "-f", "-", stdin_data: YAML.dump(applied_pv)).and_return(["applied", success_status])

      detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx")
      expect(intermediate_pv["spec"]["persistentVolumeReclaimPolicy"]).to eq("Delete")
    end

    it "resets retry count on source PV" do
      source_pv["metadata"]["annotations"]["csi.ubicloud.com/migration-retry-count"] = "2"
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "delete", "pvc", "data-pvc", "--wait=false", "--ignore-not-found=true", stdin_data: nil).and_return(["deleted", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "get", "pvc", "data-pvc", "-oyaml", stdin_data: nil).and_return([YAML.dump(pvc), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", remove_finalizer_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(trimmed_pvc)).and_return(["created", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      retry_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/migration-retry-count" => nil}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", retry_patch, stdin_data: nil).and_return(["patched", success_status])

      detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx")
    end

    it "patches annotation when PVC was recreated by StatefulSet controller" do
      pvc["metadata"]["uid"] = "different-uid"
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      old_pv_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", old_pv_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(real_client).not_to receive(:delete_pvc)

      detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx")
    end

    it "skips delete when PVC has deletion timestamp" do
      pvc["metadata"]["deletionTimestamp"] = "2026-01-01T00:00:00Z"
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(real_client).not_to receive(:delete_pvc)
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(trimmed_pvc)).and_return(["created", success_status])

      detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx")
    end

    it "preserves old-pv-name via ||= in trimmed PVC" do
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "delete", "pvc", "data-pvc", "--wait=false", "--ignore-not-found=true", stdin_data: nil).and_return(["deleted", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "get", "pvc", "data-pvc", "-oyaml", stdin_data: nil).and_return([YAML.dump(pvc), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", remove_finalizer_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(trimmed_pvc)).and_return(["created", success_status])

      detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx")
    end

    it "patches annotation when create_pvc fails with AlreadyExists" do
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      old_pv_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "delete", "pvc", "data-pvc", "--wait=false", "--ignore-not-found=true", stdin_data: nil).and_return(["deleted", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "get", "pvc", "data-pvc", "-oyaml", stdin_data: nil).and_return([YAML.dump(pvc), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", remove_finalizer_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(trimmed_pvc)).and_return(["Error from server (AlreadyExists): already exists", failed_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", old_pv_patch, stdin_data: nil).and_return(["patched", success_status])

      detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx")
    end

    it "re-raises non-AlreadyExists errors from create_pvc" do
      trimmed_pvc = {"metadata" => {"namespace" => "default", "name" => "data-pvc", "annotations" => {"csi.ubicloud.com/old-pv-name" => "pvc-xxx"}}, "spec" => {"accessModes" => ["ReadWriteOnce"]}}
      old_pvc_object_patch = {"metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => Base64.strict_encode64(YAML.dump(trimmed_pvc))}}}.to_json
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "pv", "pvc-xxx", "-oyaml", stdin_data: nil).and_return([YAML.dump(source_pv), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "patch", "pv", "pvc-xxx", "--type=merge", "-p", old_pvc_object_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "delete", "pvc", "data-pvc", "--wait=false", "--ignore-not-found=true", stdin_data: nil).and_return(["deleted", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "get", "pvc", "data-pvc", "-oyaml", stdin_data: nil).and_return([YAML.dump(pvc), success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "default", "patch", "pvc", "data-pvc", "--type=merge", "-p", remove_finalizer_patch, stdin_data: nil).and_return(["patched", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(trimmed_pvc)).and_return(["Error from server (Forbidden): forbidden", failed_status])

      expect { detector.recover_stuck_pvc(real_client, pvc, intermediate_pv, "pvc-xxx") }.to raise_error(RuntimeError, /Forbidden/)
    end
  end
end
