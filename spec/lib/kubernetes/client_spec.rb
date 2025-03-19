# frozen_string_literal: true

RSpec.describe Kubernetes::Client do
  let(:project) { Project.create(name: "test") }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location: "hetzner-hel1", net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:kubernetes_cluster) {
    KubernetesCluster.create(
      name: "test",
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: private_subnet.id,
      location: "hetzner-fsn1",
      project_id: project.id,
      target_node_size: "standard-2"
    )
  }
  let(:session) { instance_double(Net::SSH::Connection::Session) }
  let(:kubernetes_client) { described_class.new(kubernetes_cluster, session) }

  describe "is_service_deleted" do
    it "detects deleted service" do
      svc = {
        "metadata" => {
          "deletionTimestamp" => "asdf"
        }
      }
      expect(kubernetes_client.is_service_deleted(svc)).to be(true)
    end

    it "detects not deleted service" do
      svc = {
        "metadata" => {}
      }
      expect(kubernetes_client.is_service_deleted(svc)).to be(false)
    end
  end

  describe "lb_desired_ports" do
    it "returns desired ports" do
      svc = {
        "spec" => {
          "ports" => [
            {"port" => 80, "nodePort" => 31942},
            {"port" => 443, "nodePort" => 33212}
          ]
        }
      }
      expect(kubernetes_client.lb_desired_ports(svc)).to eq([[80, 31942], [443, 33212]])
    end
  end

  describe "load_balancer_hostname_missing?" do
    it "detects whether load_balancer hostname is set" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => {
              "hostname" => "asdf.com"
            }
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(false)
    end

    it "detects whether load_balancer hostname is not set" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => {}
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end
  end

  describe "kubectl" do
    it "runs kubectl command in the right format" do
      expect(session).to receive(:exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes")
      kubernetes_client.kubectl("get nodes")
    end
  end

  describe "set_load_balancer_host_name" do
    it "calls kubectl function with right inputs" do
      svc = {
        "metadata" => {
          "namespace" => "default",
          "name" => "test-svc"
        }
      }
      expect(kubernetes_client).to receive(:kubectl).with("-n default patch service test-svc --type=merge -p '{\"status\":{\"loadBalancer\":{\"ingress\":[{\"hostname\":\"asdf.com\"}]}}}' --subresource=status")
      kubernetes_client.set_load_balancer_host_name(svc, "asdf.com")
    end
  end

  describe "vm_diff_for_lb" do
    it "finds the extra and missing vms" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 443, dst_port: 8443).subject
      extra_vm = Prog::Vm::Nexus.assemble("key", project.id, name: "extra-vm", private_subnet_id: private_subnet.id).subject
      missing_vm = Prog::Vm::Nexus.assemble("key", project.id, name: "missing-vm", private_subnet_id: private_subnet.id).subject
      lb.add_vm(extra_vm)
      np = instance_double(KubernetesNodepool, vms: [missing_vm])
      expect(kubernetes_cluster).to receive(:nodepools).and_return([np])
      extra_vms, missing_vms = kubernetes_client.vm_diff_for_lb
      expect(extra_vms.count).to eq(1)
      expect(extra_vms[0].id).to eq(extra_vm.id)
      expect(missing_vms.count).to eq(1)
      expect(missing_vms[0].id).to eq(missing_vm.id)
    end
  end

  describe "port_diff_for_lb" do
    it "finds the extra and missing vms" do
      Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 80, dst_port: 8000).subject
      extra_ports, missing_ports = kubernetes_client.port_diff_for_lb([[443, 8443]])
      expect(extra_ports.count).to eq(1)
      expect(extra_ports[0].src_port).to eq(80)
      expect(missing_ports.count).to eq(1)
      expect(missing_ports[0][0]).to eq(443)
    end
  end

  describe "lb_service_modified?" do
    before do
      @svc = {}
    end

    it "determines lb_service is modified because of deletion" do
      expect(kubernetes_client).to receive_messages(
        is_service_deleted: true,
        is_service_finalized: true
      )
      expect(kubernetes_client.lb_service_modified?(@svc)).to be(true)
    end

    it "determines lb_service is modified because its LoadBalancer is not created" do
      allow(kubernetes_client).to receive_messages(
        is_service_deleted: false
      )
      expect(kubernetes_client.lb_service_modified?(@svc)).to be(true)
    end

    it "determines lb_service is modified because vm_diff is not empty" do
      Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 80, dst_port: 8000).subject
      allow(kubernetes_client).to receive_messages(
        is_service_deleted: false,
        vm_diff_for_lb: [[instance_double(Vm)], []]
      )
      expect(kubernetes_client.lb_service_modified?(@svc)).to be(true)

      allow(kubernetes_client).to receive(:vm_diff_for_lb).and_return([[], [instance_double(Vm)]])
      expect(kubernetes_client.lb_service_modified?(@svc)).to be(true)
    end

    it "determines lb_service is modified because port_diff is not empty" do
      Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 80, dst_port: 8000).subject
      allow(kubernetes_client).to receive_messages(
        is_service_deleted: false,
        vm_diff_for_lb: [[], []],
        lb_desired_ports: [[80, 30212]],
        port_diff_for_lb: [[instance_double(LoadBalancerPort)], []]
      )
      expect(kubernetes_client.lb_service_modified?(@svc)).to be(true)

      allow(kubernetes_client).to receive(:port_diff_for_lb).and_return([[], [[443, 30222]]])
      expect(kubernetes_client.lb_service_modified?(@svc)).to be(true)
    end

    it "determines lb_service is modified because hostname is not set" do
      Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 80, dst_port: 8000).subject
      allow(kubernetes_client).to receive_messages(
        is_service_deleted: false,
        vm_diff_for_lb: [[], []],
        lb_desired_ports: [[80, 32222]],
        port_diff_for_lb: [[], []],
        load_balancer_hostname_missing?: true
      )
      expect(kubernetes_client.lb_service_modified?(@svc)).to be(true)
    end
  end

  describe "any_lb_services_modified?" do
    it "detects that none of the services were modified" do
      response = {
        "items" => [
          {},
          {}
        ]
      }.to_json
      expect(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(response)
      allow(kubernetes_client).to receive(:lb_service_modified?).and_return(false)
      expect(kubernetes_client.any_lb_services_modified?).to be(false)
    end

    it "detects that one of the services were modified" do
      response = {
        "items" => [
          {}
        ]
      }.to_json
      expect(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(response)
      allow(kubernetes_client).to receive(:lb_service_modified?).and_return(true)
      expect(kubernetes_client.any_lb_services_modified?).to be(true)
    end
  end

  describe "reconcile_kubernetes_service" do
    before do
      @svc = {}
    end

    it "returns early" do
      expect(kubernetes_client).to receive(:is_service_deleted).and_return(true)
      kubernetes_client.reconcile_kubernetes_service(@svc)
    end

    it "reconciles with pre existing lb with not ready loadbalancer" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 443, dst_port: 8443).subject
      lb.strand.update(label: "not waiting")
      missing_port = [80, 8000]
      missing_vm = create_vm
      extra_vm = create_vm
      allow(kubernetes_client).to receive_messages(
        is_service_deleted: false,
        vm_diff_for_lb: [[extra_vm], [missing_vm]],
        port_diff_for_lb: [[lb.ports.first], [missing_port]],
        lb_desired_ports: [[30122, 80]]
      )
      expect(kubernetes_client).not_to receive(:set_load_balancer_host_name)
      kubernetes_client.reconcile_kubernetes_service(@svc)
    end

    it "reconciles with pre existing lb with ready loadbalancer" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 443, dst_port: 8443).subject
      missing_port = [80, 8000]
      missing_vm = create_vm
      extra_vm = create_vm
      allow(kubernetes_client).to receive_messages(
        is_service_deleted: false,
        vm_diff_for_lb: [[extra_vm], [missing_vm]],
        port_diff_for_lb: [[lb.ports.first], [missing_port]],
        lb_desired_ports: [[30122, 80]]
      )
      expect(kubernetes_client).to receive(:set_load_balancer_host_name)
      kubernetes_client.reconcile_kubernetes_service(@svc)
    end

    it "raises error with non existing lb" do
      allow(kubernetes_client).to receive_messages(
        is_service_deleted: false,
        lb_desired_ports: [[80, 30122]]
      )
      expect { kubernetes_client.reconcile_kubernetes_service({}) }.to raise_error RuntimeError, "services LoadBalancer does not exist."
    end
  end

  describe "sync_kubernetes_services" do
    it "syncs kubernetes services" do
      response = {
        "items" => [
          {},
          {}
        ]
      }.to_json.to_s
      expect(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(response)
      allow(kubernetes_client).to receive(:reconcile_kubernetes_service)
      kubernetes_client.sync_kubernetes_services
    end
  end
end
