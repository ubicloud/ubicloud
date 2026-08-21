# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodeNexus do
  subject(:nx) { described_class.new(kd.strand) }

  let(:project) { Project.create(name: "default") }
  let(:kc) {
    kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: "cluster",
      version: Option.selectable_kubernetes_versions.first,
      cp_node_count: 3,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-2",
    ).subject

    lb = LoadBalancer.create(private_subnet_id: kc.private_subnet_id, name: "lb", health_check_endpoint: "/", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.update(api_server_lb_id: lb.id)

    services_lb = LoadBalancer.create(private_subnet_id: kc.private_subnet_id, name: "services_lb", health_check_endpoint: "/", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: services_lb.id, src_port: 123, dst_port: 456)
    kc.update(services_lb_id: services_lb.id)

    kc
  }
  let(:kd) { described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  describe ".assemble" do
    it "creates a kubernetes node" do
      st = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm2", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil)
      kd = st.subject

      expect(kd.vm.name).to eq "vm2"
      expect(kd.ubid).to start_with("kd")
      expect(kd.kubernetes_cluster_id).to eq kc.id
      expect(st.label).to eq "start"
      expect(kd.kubernetes_cluster.private_subnet.net4.netmask.prefix_len).to eq 16
    end

    it "attaches internal cp vm firewall to control plane node" do
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm2", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject
      expect(node.vm.vm_firewalls).to eq [kc.internal_cp_vm_firewall]
    end

    it "attaches internal worker vm firewall to nodepool node" do
      kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm2", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id).subject
      expect(node.vm.vm_firewalls).to eq [kc.internal_worker_vm_firewall]
    end

    it "excludes hosts that already have other CP VMs" do
      host = create_vm_host
      vm = create_vm(vm_host: host)
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id)

      # Two VMs, one doesn't have a host yet, but the prog still works
      expect(kd.vm.vm_host_id).to be_nil
      expect(kc.reload.nodes.count).to eq 2
      existing_hosts = [vm.vm_host_id]

      expect(Config).to receive(:allow_unspread_servers).and_return(false)
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "node3", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject
      expect(node.vm.strand.stack[0]["exclude_host_ids"]).to eq existing_hosts

      expect(Config).to receive(:allow_unspread_servers).and_return(true)
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "node4", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject
      expect(node.vm.strand.stack[0]["exclude_host_ids"]).to eq []
    end

    it "doesn't exclude hosts when creating worker nodes" do
      kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 3, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
      host = create_vm_host
      vm = create_vm(vm_host: host)
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)

      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm3", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id).subject
      expect(node.kubernetes_nodepool).to eq kn
      expect(node.vm.strand.stack[0]["exclude_host_ids"]).to eq []
    end
  end

  describe "#start" do
    it "hops to wait" do
      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for 6 hours" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to retire when semaphore is set" do
      nx.incr_retire
      expect { nx.wait }.to hop("retire")
    end

    it "hops to unavailable when checkup semaphore is set" do
      nx.incr_checkup
      expect { nx.wait }.to hop("unavailable")
    end

    it "hops to renew_certs when renew_certs semaphore is set" do
      nx.incr_renew_certs
      expect { nx.wait }.to hop("renew_certs")
    end

    it "hops to configure_metrics when configure_metrics semaphore is set" do
      nx.incr_configure_metrics
      expect { nx.wait }.to hop("configure_metrics")
    end
  end

  describe "#configure_metrics" do
    def expect_collector_setup(sshable)
      expect(sshable).to receive(:_cmd).with("mkdir -p /home/ubi/kubernetes/metrics")
      expect(sshable).to receive(:_cmd).with("tee /home/ubi/kubernetes/metrics/config.json > /dev/null", stdin: nx.metrics_config.to_json)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/kubernetes-metrics.service > /dev/null", stdin: nx.metrics_service)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/kubernetes-metrics.timer > /dev/null", stdin: nx.metrics_timer)
      expect(sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now kubernetes-metrics.timer")
    end

    it "hops to configure_prometheus on a control plane node and registers a wait deadline" do
      nx.incr_configure_metrics
      expect_collector_setup(nx.kubernetes_node.sshable)

      expect { nx.configure_metrics }.to hop("configure_prometheus")

      expect(kd.configure_metrics_set?).to be false
      frame = nx.strand.stack.first
      expect(frame["deadline_target"]).to eq "wait"
      expect(Time.new(frame["deadline_at"].to_s)).to be_within(3).of(Time.now + 30 * 60)
    end

    it "skips prometheus on a worker node" do
      kd.update(kubernetes_nodepool_id: Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id).subject.id)
      expect_collector_setup(nx.kubernetes_node.sshable)

      expect { nx.configure_metrics }.to hop("wait")
    end
  end

  describe "#configure_prometheus" do
    def expect_token_read(encoded)
      ssh_session = Net::SSH::Connection::Session.allocate
      expect(nx.cluster.sshable).to receive(:connect).and_return(ssh_session)
      expect(ssh_session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s -n kube-system get secret prometheus-metrics -o jsonpath='{.data.token}' --ignore-not-found").and_return(Net::SSH::Connection::Session::StringWithExitstatus.new(encoded, 0))
    end

    it "writes the token and config, then starts prometheus" do
      sshable = nx.kubernetes_node.sshable
      expect_token_read(Base64.strict_encode64("sa-token"))
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/prometheus/token > /dev/null", stdin: "sa-token")
      expect(sshable).to receive(:_cmd).with("sudo chown prometheus:prometheus /etc/prometheus/token")
      expect(sshable).to receive(:_cmd).with("sudo chmod 600 /etc/prometheus/token")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/prometheus/prometheus.yml > /dev/null", stdin: nx.prometheus_config)
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/prometheus/rules.yml > /dev/null", stdin: nx.prometheus_rules)
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now prometheus")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload prometheus")

      expect { nx.configure_prometheus }.to hop("wait")
    end

    it "naps without redoing any work until the service account token exists" do
      expect_token_read("")

      expect { nx.configure_prometheus }.to nap(10)
    end
  end

  describe "#renew_certs" do
    def node_sshable
      nx.kubernetes_node.sshable
    end

    it "registers a 10-minute wait deadline on every entry" do
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check renew_certs").and_return("InProgress")
      expect { nx.renew_certs }.to nap(30)
      frame = nx.strand.stack.first
      expect(frame["deadline_target"]).to eq("wait")
      expect(Time.new(frame["deadline_at"].to_s)).to be_within(3).of(Time.now + 10 * 60)
    end

    it "starts the daemonizer, marks the node renewing_certs and naps when not started" do
      nx.incr_renew_certs
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check renew_certs").and_return("NotStarted")
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run renew_certs /home/ubi/kubernetes/bin/renew-certs", {log: true, stdin: nil})
      expect { nx.renew_certs }.to nap(30)
      expect(kd.reload.state).to eq("renewing_certs")
      expect(kd.renew_certs_set?).to be false
    end

    it "naps when the daemonizer is in progress" do
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check renew_certs").and_return("InProgress")
      expect { nx.renew_certs }.to nap(30)
    end

    it "cleans the daemonizer, marks node active and hops to wait on success" do
      kd.update(state: "renewing_certs")
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check renew_certs").and_return("Succeeded")
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean renew_certs")
      expect { nx.renew_certs }.to hop("wait")
      expect(kd.reload.state).to eq("active")
    end

    it "naps when the daemonizer fails so the deadline mechanism can fire" do
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check renew_certs").and_return("Failed")
      expect { nx.renew_certs }.to nap(30)
    end

    it "naps when the daemonizer returns an unknown state" do
      expect(node_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check renew_certs").and_return("unknown")
      expect(Clog).to receive(:emit).with("got unknown state from daemonizer2 check: unknown", {kubernetes_node: {ubid: kd.ubid, name: kd.name}})
      expect { nx.renew_certs }.to nap(30)
    end
  end

  describe "#unavailable" do
    it "hops to retire when retire semaphore is set" do
      nx.incr_retire
      expect { nx.unavailable }.to hop("retire")
    end

    it "hops to wait when node becomes available" do
      nx.incr_checkup
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => true}}, "external_endpoints" => {}})
      expect(nx.kubernetes_node.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect { nx.unavailable }.to hop("wait")
      expect(kd.checkup_set?(cached: false)).to be false
    end

    it "logs, registers deadline and naps when still unavailable" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => false}}, "external_endpoints" => {}})
      expect(nx.kubernetes_node.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect { nx.unavailable }.to nap(15)
      frame = nx.strand.stack.first
      expect(frame["deadline_target"]).to eq("wait")
      expect(Time.new(frame["deadline_at"].to_s)).to be_within(3).of(Time.now + 15 * 60)
    end
  end

  describe "#available?" do
    it "returns true when all pods are reachable" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => true}}, "external_endpoints" => {}})
      expect(nx.kubernetes_node.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(nx.available?).to be true
    end

    it "returns false when a pod is unreachable" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => false}}, "external_endpoints" => {}})
      expect(nx.kubernetes_node.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect(nx.available?).to be false
    end
  end

  describe "#drain" do
    def cluster_sshable
      nx.cluster.sshable
    end

    it "starts the drain process when run for the first time and naps" do
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check drain_node_vm").and_return("NotStarted")
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run drain_node_vm sudo kubectl --kubeconfig\\=/etc/kubernetes/admin.conf drain vm --ignore-daemonsets --delete-emptydir-data", {log: true, stdin: nil})
      expect { nx.drain }.to nap(10)
    end

    it "naps when the node is getting drained" do
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check drain_node_vm").and_return("InProgress")
      expect { nx.drain }.to nap(10)
    end

    it "restarts when it fails" do
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check drain_node_vm").and_return("Failed")
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 restart drain_node_vm")
      expect { nx.drain }.to nap(10)
    end

    it "naps when daemonizer something unexpected and waits for the page" do
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check drain_node_vm").and_return("UnexpectedState")

      expect { nx.drain }.to nap(3 * 60 * 60)

      frame = nx.strand.stack.first
      expect(frame["deadline_target"]).to eq "destroy"
      expect(Time.new(frame["deadline_at"])).to be_within(3).of(Time.now)
    end

    it "drains the old node and hops to wait_for_detach" do
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check drain_node_vm").and_return("Succeeded")
      expect { nx.drain }.to hop("wait_for_detach")
    end
  end

  describe "#wait_for_detach" do
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:success_response) { Net::SSH::Connection::Session::StringWithExitstatus.new("", 0) }

    before do
      expect(nx.cluster.sshable).to receive(:connect).and_return(session)
    end

    it "naps when ubicsi VolumeAttachments still reference this node" do
      va_list = {"items" => [{
        "spec" => {"nodeName" => nx.kubernetes_node.name, "attacher" => "csi.ubicloud.com"},
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get volumeattachments -ojson").and_return(success_response.replace(JSON.generate(va_list)))
      expect { nx.wait_for_detach }.to nap(5)
    end

    it "hops to wait_for_copy when no VolumeAttachments reference this node" do
      va_list = {"items" => []}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get volumeattachments -ojson").and_return(success_response.replace(JSON.generate(va_list)))
      expect { nx.wait_for_detach }.to hop("wait_for_copy")
    end

    it "hops to wait_for_copy when only non-ubicsi VolumeAttachments remain on this node" do
      va_list = {"items" => [{
        "spec" => {"nodeName" => nx.kubernetes_node.name, "attacher" => "other-csi-driver"},
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get volumeattachments -ojson").and_return(success_response.replace(JSON.generate(va_list)))
      expect { nx.wait_for_detach }.to hop("wait_for_copy")
    end

    it "hops to wait_for_copy when ubicsi VolumeAttachments reference a different node" do
      va_list = {"items" => [{
        "spec" => {"nodeName" => "other-node", "attacher" => "csi.ubicloud.com"},
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get volumeattachments -ojson").and_return(success_response.replace(JSON.generate(va_list)))
      expect { nx.wait_for_detach }.to hop("wait_for_copy")
    end
  end

  describe "#wait_for_copy" do
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:success_response) { Net::SSH::Connection::Session::StringWithExitstatus.new("", 0) }

    before do
      expect(nx.cluster.sshable).to receive(:connect).and_return(session)
    end

    it "naps when a Bound PV without a migration annotation still lives on this node" do
      pv_list = {"items" => [{
        "metadata" => {"name" => "pv-1"},
        "status" => {"phase" => "Bound"},
        "spec" => {
          "csi" => {"driver" => "csi.ubicloud.com"},
          "persistentVolumeReclaimPolicy" => "Delete",
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => [nx.kubernetes_node.name]}]}]}},
        },
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to nap(15)
    end

    it "naps when a PV with old-pvc-object annotation references this node" do
      pv_list = {"items" => [{
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => "some-data"}},
        "spec" => {
          "csi" => {"driver" => "csi.ubicloud.com"},
          "persistentVolumeReclaimPolicy" => "Retain",
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => [nx.kubernetes_node.name]}]}]}},
        },
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to nap(15)
    end

    it "hops to remove_node_from_cluster when no PVs reference this node" do
      pv_list = {"items" => []}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to hop("remove_node_from_cluster")
    end

    it "hops to remove_node_from_cluster when PVs reference a different node" do
      pv_list = {"items" => [{
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => "some-data"}},
        "spec" => {
          "csi" => {"driver" => "csi.ubicloud.com"},
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["other-node"]}]}]}},
        },
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to hop("remove_node_from_cluster")
    end

    it "hops to remove_node_from_cluster when a Bound PV on this node belongs to another driver" do
      pv_list = {"items" => [{
        "metadata" => {"name" => "pv-foreign"},
        "status" => {"phase" => "Bound"},
        "spec" => {
          "csi" => {"driver" => "other-csi-driver"},
          "persistentVolumeReclaimPolicy" => "Delete",
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => [nx.kubernetes_node.name]}]}]}},
        },
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to hop("remove_node_from_cluster")
    end

    it "hops to remove_node_from_cluster when PV has Delete reclaim policy (rolled-back chained migration)" do
      pv_list = {"items" => [{
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => "some-data"}},
        "spec" => {
          "csi" => {"driver" => "csi.ubicloud.com"},
          "persistentVolumeReclaimPolicy" => "Delete",
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => [nx.kubernetes_node.name]}]}]}},
        },
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to hop("remove_node_from_cluster")
    end
  end

  describe "#retire" do
    it "registers a destroy deadline, updates the state and hops to retain_volumes" do
      expect { nx.retire }.to hop("retain_volumes")
      expect(kd.reload.state).to eq("draining")
      expect(nx.strand.stack.first["deadline_target"]).to eq("destroy")
    end
  end

  describe "#retain_volumes" do
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:success_response) { Net::SSH::Connection::Session::StringWithExitstatus.new("", 0) }

    before do
      allow(nx.cluster.sshable).to receive(:connect).and_return(session)
    end

    def pv(name:, phase:, policy:, node:, driver: "csi.ubicloud.com")
      {
        "metadata" => {"name" => name},
        "status" => {"phase" => phase},
        "spec" => {
          "csi" => {"driver" => driver},
          "persistentVolumeReclaimPolicy" => policy,
          "nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => [node]}]}]}},
        },
      }
    end

    it "retains bound Delete PVs pinned to this node and hops to drain" do
      pv_list = {"items" => [pv(name: "pv-bound", phase: "Bound", policy: "Delete", node: nx.kubernetes_node.name)]}
      get_response = Net::SSH::Connection::Session::StringWithExitstatus.new(JSON.generate(pv_list), 0)
      patch_response = Net::SSH::Connection::Session::StringWithExitstatus.new("", 0)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(get_response)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s patch pv pv-bound --type=merge -p \\{\\\"spec\\\":\\{\\\"persistentVolumeReclaimPolicy\\\":\\\"Retain\\\"\\}\\}").and_return(patch_response)
      expect { nx.retain_volumes }.to hop("drain")
    end

    it "skips PVs that are already Retain, not Bound, on another node, or from another driver" do
      pv_list = {"items" => [
        pv(name: "pv-retain", phase: "Bound", policy: "Retain", node: nx.kubernetes_node.name),
        pv(name: "pv-released", phase: "Released", policy: "Delete", node: nx.kubernetes_node.name),
        pv(name: "pv-other", phase: "Bound", policy: "Delete", node: "other-node"),
        pv(name: "pv-foreign", phase: "Bound", policy: "Delete", node: nx.kubernetes_node.name, driver: "other-csi-driver"),
      ]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.retain_volumes }.to hop("drain")
    end
  end

  describe "#remove_node_from_cluster" do
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:success_response) { Net::SSH::Connection::Session::StringWithExitstatus.new("", 0) }

    def node_sshable
      nx.kubernetes_node.sshable
    end

    def cluster
      @cluster ||= nx.cluster
    end

    before do
      expect(cluster.sshable).to receive(:connect).and_return(session)
      expect(node_sshable).to receive(:_cmd).with("sudo kubeadm reset --force")
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=30s delete node vm").and_return(success_response)
    end

    it "detaches a nodepool node from the services load balancer" do
      kn = Prog::Kubernetes::KubernetesNodepoolNexus.assemble(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2").subject
      nx.kubernetes_node.update(kubernetes_nodepool_id: kn.id)
      cluster.services_lb.add_vm(nx.kubernetes_node.vm)

      expect { nx.remove_node_from_cluster }.to hop("destroy")

      expect(cluster.services_lb.vm_ports_by_vm(nx.kubernetes_node.vm).order(:stack).select_map([:stack, :state])).to eq [["ipv4", "detaching"], ["ipv6", "detaching"]]
    end

    it "detaches a control plane node from the api server load balancer" do
      cluster.api_server_lb.add_vm(nx.kubernetes_node.vm)

      expect { nx.remove_node_from_cluster }.to hop("destroy")

      expect(cluster.api_server_lb.vm_ports_by_vm(nx.kubernetes_node.vm).order(:stack).select_map([:stack, :state])).to eq [["ipv4", "detaching"], ["ipv6", "detaching"]]
    end
  end

  describe "#destroy" do
    it "destroys the vm and itself" do
      vm_id = kd.vm.id
      expect { nx.destroy }.to exit({"msg" => "kubernetes node is deleted"})
      expect(Semaphore.where(strand_id: vm_id, name: "destroy").count).to eq(1)
      expect(kd.exists?).to be false
      expect(Semaphore.where(strand_id: kc.id, name: "sync_internal_dns_config").count).to eq(1)
      expect(Semaphore.where(strand_id: kc.id, name: "sync_worker_mesh").count).to eq(1)
      expect(Semaphore.where(strand_id: kc.id, name: "update_billing_records").count).to eq(1)
    end

    it "resolves the metrics backlog page so it does not orphan" do
      Prog::PageNexus.assemble("#{kd.ubid} metrics backlog high", ["KubernetesMetricsBacklogHigh", kd.id], kd.ubid, severity: "warning", extra_data: {metrics_backlog: 30})
      page = Page.from_tag_parts("KubernetesMetricsBacklogHigh", kd.id)

      expect { nx.destroy }.to exit({"msg" => "kubernetes node is deleted"})

      expect(page.semaphores_dataset.map(:name)).to eq ["resolve"]
    end
  end
end
