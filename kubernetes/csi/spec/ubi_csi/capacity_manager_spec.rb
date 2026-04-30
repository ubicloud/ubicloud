# frozen_string_literal: true

require "logger"
require "spec_helper"

RSpec.describe Csi::CapacityManager do
  let(:logger) { Logger.new(File::NULL) }
  let(:max_volume_size) { 10 * 1024 * 1024 * 1024 }
  let(:manager) { described_class.new(logger:, max_volume_size:) }
  let(:success_status) { instance_double(Process::Status, success?: true) }
  let(:failure_status) { instance_double(Process::Status, success?: false) }

  after { manager.shutdown! }

  describe ".parse_capacity_output" do
    it "parses header and staged ids" do
      result = described_class.parse_capacity_output("100 50 10\nvol-a\nvol-b\n")
      expect(result).to eq(df_total: 100, df_avail: 50, uncommitted: 10, staged_ids: ["vol-a", "vol-b"])
    end

    it "returns empty staged_ids when no backing files" do
      expect(described_class.parse_capacity_output("100 50 10\n")[:staged_ids]).to eq([])
    end

    it "tolerates trailing whitespace and blank lines" do
      expect(described_class.parse_capacity_output("100 50 10\n\nvol-a\n  \nvol-b\n")[:staged_ids]).to eq(["vol-a", "vol-b"])
    end

    it "raises when the header has the wrong arity" do
      expect { described_class.parse_capacity_output("100 50\nvol-a\n") }.to raise_error(RuntimeError, "Unexpected capacity output: \"100 50\\nvol-a\\n\"")
    end

    it "raises when the header is non-numeric" do
      expect { described_class.parse_capacity_output("a b c\n") }.to raise_error(ArgumentError, 'invalid value for Integer(): "a"')
    end
  end

  describe ".parse_quantity" do
    it "parses plain integers" do
      expect(described_class.parse_quantity("3260544000")).to eq(3260544000)
      expect(described_class.parse_quantity("0")).to eq(0)
    end

    it "parses decimal SI suffixes (kube-apiserver normalizes byte counts to these)" do
      expect(described_class.parse_quantity("3260544k")).to eq(3260544 * 1000)
      expect(described_class.parse_quantity("16106127360")).to eq(16106127360)
      expect(described_class.parse_quantity("1M")).to eq(1_000_000)
      expect(described_class.parse_quantity("2.5G")).to eq(2_500_000_000)
    end

    it "parses binary suffixes" do
      expect(described_class.parse_quantity("15Gi")).to eq(15 * 1024**3)
      expect(described_class.parse_quantity("1Ki")).to eq(1024)
    end

    it "treats nil and empty strings as zero" do
      expect(described_class.parse_quantity(nil)).to eq(0)
      expect(described_class.parse_quantity("")).to eq(0)
      expect(described_class.parse_quantity("  ")).to eq(0)
    end

    it "raises on unrecognized formats" do
      expect { described_class.parse_quantity("garbage") }.to raise_error(ArgumentError, /Unrecognized Kubernetes quantity/)
    end
  end

  describe "#start" do
    it "fetches the owner ref and spawns the reconcile thread" do
      deploy_yaml = YAML.dump({
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => {"name" => "ubicsi-provisioner", "uid" => "deploy-uid"},
      })
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "get", "deployment", "ubicsi-provisioner", "-oyaml",
        stdin_data: nil,
      ).and_return([deploy_yaml, success_status])
      sync = Queue.new
      expect(manager).to receive(:reconcile) { sync.push(true) }

      manager.start
      expect(sync.pop(timeout: 1)).to be true
      expect(manager.instance_variable_get(:@owner_ref)).to eq({
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "name" => "ubicsi-provisioner",
        "uid" => "deploy-uid",
        "controller" => true,
      })
    end

    it "raises when the owner_ref lookup fails so the controller pod crashes" do
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "get", "deployment", "ubicsi-provisioner", "-oyaml",
        stdin_data: nil,
      ).and_return(["api error", failure_status])
      expect(manager).not_to receive(:spawn_reconcile_thread)
      expect { manager.start }.to raise_error(RuntimeError, "Command failed: kubectl -n ubicsi get deployment ubicsi-provisioner -oyaml\nOutput: api error")
    end
  end

  describe "#shutdown!" do
    it "is a no-op when the thread was never started" do
      expect { manager.shutdown! }.not_to raise_error
      expect(manager.instance_variable_get(:@queue)).to be_closed
    end

    it "logs reconcile errors and keeps the loop alive" do
      deploy_yaml = YAML.dump({
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => {"name" => "ubicsi-provisioner", "uid" => "deploy-uid"},
      })
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "get", "deployment", "ubicsi-provisioner", "-oyaml",
        stdin_data: nil,
      ).and_return([deploy_yaml, success_status])
      sync = Queue.new
      expect(manager).to receive(:reconcile) do
        sync.push(true)
        raise StandardError.new("error")
      end.at_least(:once)
      expect(logger).to receive(:error).with(start_with("[CapacityManager] reconcile failed: StandardError - error\n")).at_least(:once)

      manager.start
      expect(sync.pop(timeout: 1)).to be true
      manager.shutdown!
    end
  end

  describe "#reserve" do
    before do
      manager.instance_variable_set(:@owner_ref, {"name" => "ubicsi-provisioner"})
      manager.instance_variable_set(:@known, {
        "worker-1" => {
          "ubicloud-standard" => {
            object_name: "csisc-worker-1-ubicloud-standard",
            base_capacity: 50_000_000,
            last_published: 50_000_000,
          },
        },
      })
    end

    it "subtracts the reservation from the published capacity, patches, and returns true" do
      # max_volume_size = min(published 40M, global 10G) = 40M
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "patch", "csistoragecapacity", "csisc-worker-1-ubicloud-standard",
        "--type=merge", "-p", '{"capacity":"40000000","maximumVolumeSize":"40000000"}',
        stdin_data: nil,
      ).and_return(["patched", success_status])

      expect(manager.reserve(hostname: "worker-1", vol_id: "vol-a", size_bytes: 10_000_000)).to be true

      expect(manager.instance_variable_get(:@pending)["worker-1"]["vol-a"][:size]).to eq(10_000_000)
      expect(manager.instance_variable_get(:@known)["worker-1"]["ubicloud-standard"][:last_published]).to eq(40_000_000)
    end

    it "rejects the reservation, returns false, and does not patch when it would overcommit" do
      expect(manager.kubernetes_client).not_to receive(:patch_csi_storage_capacity)
      expect(manager.reserve(hostname: "worker-1", vol_id: "vol-a", size_bytes: 999_999_999)).to be false
      expect(manager.instance_variable_get(:@pending)["worker-1"]).to be_nil
    end

    it "trusts the scheduler when the host is not yet in @known and skips the patch" do
      expect(manager.kubernetes_client).not_to receive(:patch_csi_storage_capacity)
      expect(manager.reserve(hostname: "unknown-host", vol_id: "vol-a", size_bytes: 10_000_000)).to be true
      expect(manager.instance_variable_get(:@pending)["unknown-host"]["vol-a"][:size]).to eq(10_000_000)
    end

    it "logs and continues when the patch fails" do
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "patch", "csistoragecapacity", "csisc-worker-1-ubicloud-standard",
        "--type=merge", "-p", '{"capacity":"40000000","maximumVolumeSize":"40000000"}',
        stdin_data: nil,
      ).and_return(["api down", failure_status])
      expect(logger).to receive(:error).with(
        %([CapacityManager] patch failed for csisc-worker-1-ubicloud-standard: RuntimeError - Command failed: kubectl -n ubicsi patch csistoragecapacity csisc-worker-1-ubicloud-standard --type=merge -p {"capacity":"40000000","maximumVolumeSize":"40000000"}\nOutput: api down),
      )
      manager.reserve(hostname: "worker-1", vol_id: "vol-a", size_bytes: 10_000_000)
    end
  end

  describe "#release" do
    before do
      manager.instance_variable_set(:@pending, {
        "worker-1" => {"vol-a" => {size: 10_000_000, created_at: Time.now}},
      })
      manager.instance_variable_set(:@known, {
        "worker-1" => {
          "ubicloud-standard" => {
            object_name: "csisc-worker-1-ubicloud-standard",
            base_capacity: 50_000_000,
            last_published: 40_000_000,
          },
        },
      })
    end

    it "drops the pending entry and republishes" do
      # max_volume_size = min(published 50M, global 10G) = 50M
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "patch", "csistoragecapacity", "csisc-worker-1-ubicloud-standard",
        "--type=merge", "-p", '{"capacity":"50000000","maximumVolumeSize":"50000000"}',
        stdin_data: nil,
      ).and_return(["patched", success_status])

      manager.release(vol_id: "vol-a")
      expect(manager.instance_variable_get(:@pending)["worker-1"]).to be_empty
    end

    it "is a no-op when the vol_id is not tracked" do
      expect(manager.kubernetes_client).not_to receive(:patch_csi_storage_capacity)
      manager.release(vol_id: "vol-unknown")
    end

    it "skips the patch when nothing changed" do
      manager.instance_variable_get(:@known)["worker-1"]["ubicloud-standard"][:last_published] = 50_000_000
      expect(manager.kubernetes_client).not_to receive(:patch_csi_storage_capacity)
      manager.release(vol_id: "vol-a")
    end
  end

  describe "#reconcile" do
    let(:csinodes_yaml) do
      YAML.dump({"items" => [
        {"metadata" => {"name" => "worker-1"}, "spec" => {"drivers" => [{"name" => "csi.ubicloud.com"}]}},
      ]})
    end
    let(:storageclasses_yaml) do
      YAML.dump({"items" => [
        {"metadata" => {"name" => "ubicloud-standard"}, "provisioner" => "csi.ubicloud.com"},
      ]})
    end
    let(:node_yaml) { YAML.dump({"status" => {"addresses" => [{"address" => "10.0.0.1"}]}}) }
    # 100 GiB total, 50 GiB available, 10 GiB uncommitted, 25% reserve, no pendings:
    # base = 50 - 10 - 25 = 15 GiB = 16_106_127_360 bytes.
    let(:capacity_output) { "107374182400 53687091200 10737418240\nvol-a\n" }
    let(:create_object) do
      {
        "apiVersion" => "storage.k8s.io/v1",
        "kind" => "CSIStorageCapacity",
        "metadata" => {
          "name" => "csisc-worker-1-ubicloud-standard",
          "namespace" => "ubicsi",
          "ownerReferences" => [{"name" => "ubicsi-provisioner"}],
        },
        "nodeTopology" => {"matchLabels" => {"kubernetes.io/hostname" => "worker-1"}},
        "storageClassName" => "ubicloud-standard",
        "capacity" => "16106127360",
        "maximumVolumeSize" => "10737418240",
      }
    end

    before do
      manager.instance_variable_set(:@owner_ref, {"name" => "ubicsi-provisioner"})
    end

    def stub_baseline(existing: [])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "csinodes", "-oyaml", stdin_data: nil).and_return([csinodes_yaml, success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "storageclasses", "-oyaml", stdin_data: nil).twice.and_return([storageclasses_yaml, success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "-n", "ubicsi", "get", "csistoragecapacities", "-oyaml", stdin_data: nil).and_return([YAML.dump({"items" => existing}), success_status])
    end

    it "creates a CSIStorageCapacity object when none exists for the (host, sc) pair" do
      stub_baseline
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([node_yaml, success_status])
      expect(Open3).to receive(:capture2e).with(
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", described_class.capacity_script,
      ).and_return([capacity_output, success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(create_object)).and_return(["created", success_status])

      manager.reconcile

      expect(manager.instance_variable_get(:@known)["worker-1"]["ubicloud-standard"][:last_published]).to eq(15 * 1024 * 1024 * 1024)
    end

    it "patches an existing object when the capacity has changed" do
      existing = [{
        "metadata" => {"name" => "csisc-existing"},
        "nodeTopology" => {"matchLabels" => {"kubernetes.io/hostname" => "worker-1"}},
        "storageClassName" => "ubicloud-standard",
        "capacity" => "999",
        "maximumVolumeSize" => "999",
      }]
      stub_baseline(existing:)
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([node_yaml, success_status])
      expect(Open3).to receive(:capture2e).with(
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", described_class.capacity_script,
      ).and_return([capacity_output, success_status])
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "patch", "csistoragecapacity", "csisc-existing",
        "--type=merge", "-p", '{"capacity":"16106127360","maximumVolumeSize":"10737418240"}',
        stdin_data: nil,
      ).and_return(["patched", success_status])

      manager.reconcile
    end

    it "does not patch when the capacity matches the published value" do
      # kube-apiserver normalizes raw byte counts into resource.Quantity
      # form on read-back: "16106127360" -> "15Gi", "10737418240" -> "10Gi".
      # parse_quantity has to handle that round-trip or we'd patch every
      # reconcile (or worse, crash on Integer()).
      existing = [{
        "metadata" => {"name" => "csisc-existing"},
        "nodeTopology" => {"matchLabels" => {"kubernetes.io/hostname" => "worker-1"}},
        "storageClassName" => "ubicloud-standard",
        "capacity" => "15Gi",
        "maximumVolumeSize" => "10Gi",
      }]
      stub_baseline(existing:)
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([node_yaml, success_status])
      expect(Open3).to receive(:capture2e).with(
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", described_class.capacity_script,
      ).and_return([capacity_output, success_status])

      expect(manager.kubernetes_client).not_to receive(:patch_csi_storage_capacity)
      expect(manager.kubernetes_client).not_to receive(:create_csi_storage_capacity)

      manager.reconcile
    end

    it "deletes orphaned objects whose (host, sc) is no longer expected" do
      existing = [
        {
          "metadata" => {"name" => "csisc-orphan"},
          "nodeTopology" => {"matchLabels" => {"kubernetes.io/hostname" => "deleted-host"}},
          "storageClassName" => "ubicloud-standard",
          "capacity" => "42",
          "maximumVolumeSize" => "42",
        },
        {
          "metadata" => {"name" => "csisc-keep"},
          "nodeTopology" => {"matchLabels" => {"kubernetes.io/hostname" => "worker-1"}},
          "storageClassName" => "ubicloud-standard",
          "capacity" => "15Gi",
          "maximumVolumeSize" => "10Gi",
        },
      ]
      stub_baseline(existing:)
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([node_yaml, success_status])
      expect(Open3).to receive(:capture2e).with(
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", described_class.capacity_script,
      ).and_return([capacity_output, success_status])
      expect(Open3).to receive(:capture2e).with(
        "kubectl", "-n", "ubicsi", "delete", "csistoragecapacity", "csisc-orphan", "--ignore-not-found=true",
        stdin_data: nil,
      ).and_return(["deleted", success_status])

      manager.reconcile

      expect(manager.instance_variable_get(:@known).keys).to eq(["worker-1"])
    end

    it "drops pending entries whose vol_id has been staged" do
      manager.instance_variable_set(:@pending, {"worker-1" => {"vol-a" => {size: 5_000_000, created_at: Time.now}}})
      stub_baseline
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([node_yaml, success_status])
      expect(Open3).to receive(:capture2e).with(
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", described_class.capacity_script,
      ).and_return([capacity_output, success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(create_object)).and_return(["created", success_status])

      manager.reconcile

      expect(manager.instance_variable_get(:@pending)["worker-1"]).to be_empty
    end

    it "drops pending entries older than the TTL" do
      manager.instance_variable_set(:@pending, {
        "worker-1" => {"vol-old" => {size: 5_000_000, created_at: Time.now - 700}},
      })
      stub_baseline
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([node_yaml, success_status])
      expect(Open3).to receive(:capture2e).with(
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", described_class.capacity_script,
      ).and_return(["107374182400 53687091200 10737418240\n", success_status])
      expect(Open3).to receive(:capture2e).with("kubectl", "create", "-f", "-", stdin_data: YAML.dump(create_object)).and_return(["created", success_status])

      manager.reconcile

      expect(manager.instance_variable_get(:@pending)["worker-1"]).to be_empty
    end

    it "skips a host when the capacity script fails" do
      stub_baseline
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return([node_yaml, success_status])
      expect(Open3).to receive(:capture2e).with(
        "ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@10.0.0.1", described_class.capacity_script,
      ).and_return(["ssh: connect failed", failure_status])
      expect(manager.kubernetes_client).not_to receive(:create_csi_storage_capacity)
      expect(manager.kubernetes_client).not_to receive(:patch_csi_storage_capacity)
      expect(logger).to receive(:error).with("[CapacityManager] capacity script on worker-1 failed: ssh: connect failed")

      manager.reconcile
    end

    it "skips a host when an exception is raised mid-fetch" do
      stub_baseline
      expect(Open3).to receive(:capture2e).with("kubectl", "get", "node", "worker-1", "-oyaml", stdin_data: nil).and_return(["api err", failure_status])
      expect(logger).to receive(:error).with(
        "[CapacityManager] fetch_node_capacity failed for worker-1: RuntimeError - Command failed: kubectl get node worker-1 -oyaml\nOutput: api err",
      )
      expect(manager.kubernetes_client).not_to receive(:create_csi_storage_capacity)

      manager.reconcile
    end
  end
end
