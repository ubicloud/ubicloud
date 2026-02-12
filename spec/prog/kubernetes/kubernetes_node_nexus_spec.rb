# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Kubernetes::KubernetesNodeNexus do
  subject(:nx) { described_class.new(kd.strand) }

  let(:project) { Project.create(name: "default") }
  let(:subnet) { Prog::Vnet::SubnetNexus.assemble(Config.kubernetes_service_project_id, name: "test", ipv4_range_size: 16, ipv6_range: "fd40:1a0a:8d48:182a::/64").subject }
  let(:kc) {
    kc = KubernetesCluster.create(
      name: "cluster",
      version: Option.kubernetes_versions.first,
      cp_node_count: 3,
      private_subnet_id: subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-2"
    )
    Firewall.create(name: "#{kc.ubid}-cp-vm-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)
    Firewall.create(name: "#{kc.ubid}-worker-vm-firewall", location_id: Location::HETZNER_FSN1_ID, project_id: Config.kubernetes_service_project_id)

    lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "lb", health_check_endpoint: "/", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 123, dst_port: 456)
    kc.update(api_server_lb_id: lb.id)

    services_lb = LoadBalancer.create(private_subnet_id: subnet.id, name: "services_lb", health_check_endpoint: "/", project_id: project.id)
    LoadBalancerPort.create(load_balancer_id: services_lb.id, src_port: 123, dst_port: 456)
    kc.update(services_lb_id: services_lb.id)

    kc
  }
  let(:kd) { described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject }

  before do
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  describe ".assemble" do
    it "creates a kubernetes node" do
      st = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm2", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil)
      kd = st.subject

      expect(kd.vm.name).to eq "vm2"
      expect(kd.ubid).to start_with("kd")
      expect(kd.kubernetes_cluster_id).to eq kc.id
      expect(st.label).to eq "start"
      expect(kd.kubernetes_cluster.private_subnet.net4.netmask.prefix_len).to eq 16
    end

    it "attaches internal cp vm firewall to control plane node" do
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm2", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject
      expect(node.vm.vm_firewalls).to eq [kc.internal_cp_vm_firewall]
    end

    it "attaches internal worker vm firewall to nodepool node" do
      kn = KubernetesNodepool.create(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm2", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id).subject
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
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "node3", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject
      expect(node.vm.strand.stack[0]["exclude_host_ids"]).to eq existing_hosts

      expect(Config).to receive(:allow_unspread_servers).and_return(true)
      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "node4", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: nil).subject
      expect(node.vm.strand.stack[0]["exclude_host_ids"]).to eq []
    end

    it "doesn't exclude hosts when creating worker nodes" do
      kn = KubernetesNodepool.create(name: "np", node_count: 3, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
      host = create_vm_host
      vm = create_vm(vm_host: host)
      KubernetesNode.create(vm_id: vm.id, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id)

      node = described_class.assemble(Config.kubernetes_service_project_id, sshable_unix_user: "ubi", name: "vm3", location_id: Location::HETZNER_FSN1_ID, size: "standard-2", storage_volumes: [{encrypted: true, size_gib: 40}], boot_image: "kubernetes-v1.33", private_subnet_id: subnet.id, enable_ip4: true, kubernetes_cluster_id: kc.id, kubernetes_nodepool_id: kn.id).subject
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
  end

  describe "#unavailable" do
    it "hops to wait when node becomes available" do
      nx.incr_checkup
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => true}}, "external_endpoints" => {}})
      expect(nx.kubernetes_node.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect { nx.unavailable }.to hop("wait")
      expect(kd.reload.checkup_set?).to be false
    end

    it "logs, registers deadline and naps when still unavailable" do
      status_json = JSON.generate({"pods" => {"pod-1" => {"reachable" => false}}, "external_endpoints" => {}})
      expect(nx.kubernetes_node.sshable).to receive(:_cmd).with("cat /var/lib/ubicsi/mesh_status.json 2>/dev/null || echo -n").and_return(status_json)
      expect { nx.unavailable }.to nap(15)
      frame = nx.strand.stack.first
      expect(frame["deadline_target"]).to eq("wait")
      expect(Time.parse(frame["deadline_at"].to_s)).to be_within(3).of(Time.now + 15 * 60)
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
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 run drain_node_vm sudo kubectl --kubeconfig\\=/etc/kubernetes/admin.conf drain vm --ignore-daemonsets --delete-emptydir-data", hash_including(log: true))
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
      expect(nx).to receive(:register_deadline).with("destroy", 0)
      expect { nx.drain }.to nap(3 * 60 * 60)
    end

    it "drains the old node and hops to wait_for_copy" do
      expect(cluster_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check drain_node_vm").and_return("Succeeded")
      expect { nx.drain }.to hop("wait_for_copy")
    end
  end

  describe "#wait_for_copy" do
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:client) { Kubernetes::Client.new(nx.cluster, session) }
    let(:success_response) { Net::SSH::Connection::Session::StringWithExitstatus.new("", 0) }

    before do
      expect(nx.cluster).to receive(:client).and_return(client)
    end

    it "naps when a PV with old-pvc-object annotation references this node" do
      pv_list = {"items" => [{
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => "some-data"}},
        "spec" => {"nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => [nx.kubernetes_node.name]}]}]}}}
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to nap(15)
    end

    it "hops to remove_node_from_cluster when no PVs reference this node" do
      pv_list = {"items" => []}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to hop("remove_node_from_cluster")
    end

    it "hops to remove_node_from_cluster when PVs reference a different node" do
      pv_list = {"items" => [{
        "metadata" => {"annotations" => {"csi.ubicloud.com/old-pvc-object" => "some-data"}},
        "spec" => {"nodeAffinity" => {"required" => {"nodeSelectorTerms" => [{"matchExpressions" => [{"values" => ["other-node"]}]}]}}}
      }]}
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pv -ojson").and_return(success_response.replace(JSON.generate(pv_list)))
      expect { nx.wait_for_copy }.to hop("remove_node_from_cluster")
    end
  end

  describe "#retire" do
    it "updates the state and hops to drain" do
      expect { nx.retire }.to hop("drain")
      expect(kd.reload.state).to eq("draining")
    end
  end

  describe "#remove_node_from_cluster" do
    let(:session) { Net::SSH::Connection::Session.allocate }
    let(:client) { Kubernetes::Client.new(cluster, session) }
    let(:success_response) { Net::SSH::Connection::Session::StringWithExitstatus.new("", 0) }

    def node_sshable
      nx.kubernetes_node.sshable
    end

    def cluster
      @cluster ||= nx.cluster
    end

    before do
      expect(cluster).to receive(:client).and_return(client)
    end

    it "runs kubeadm reset and remove nodepool node from services_lb and deletes the node from cluster" do
      kn = KubernetesNodepool.create(name: "np", node_count: 1, kubernetes_cluster_id: kc.id, target_node_size: "standard-2")
      nx.kubernetes_node.update(kubernetes_nodepool_id: kn.id)
      expect(node_sshable).to receive(:_cmd).with("sudo kubeadm reset --force")
      expect(cluster.services_lb).to receive(:detach_vm).with(nx.kubernetes_node.vm)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf delete node vm").and_return(success_response)
      expect { nx.remove_node_from_cluster }.to hop("destroy")
    end

    it "runs kubeadm reset and remove cluster node from api_server_lb and deletes the node from cluster" do
      expect(node_sshable).to receive(:_cmd).with("sudo kubeadm reset --force")
      expect(cluster.api_server_lb).to receive(:detach_vm).with(nx.kubernetes_node.vm)
      expect(session).to receive(:_exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf delete node vm").and_return(success_response)
      expect { nx.remove_node_from_cluster }.to hop("destroy")
    end
  end

  describe "#destroy" do
    before do
      Strand.create_with_id(kc, prog: "Kubernetes::KubernetesClusterNexus", label: "wait")
    end

    it "destroys the vm and itself" do
      vm_id = kd.vm.id
      expect { nx.destroy }.to exit({"msg" => "kubernetes node is deleted"})
      expect(Semaphore.where(strand_id: vm_id, name: "destroy").count).to eq(1)
      expect(kd.exists?).to be false
      expect(Semaphore.where(strand_id: kc.id, name: "sync_internal_dns_config").count).to eq(1)
      expect(Semaphore.where(strand_id: kc.id, name: "sync_worker_mesh").count).to eq(1)
    end
  end
end
