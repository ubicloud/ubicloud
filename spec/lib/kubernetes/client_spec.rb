# frozen_string_literal: true

RSpec.describe Kubernetes::Client do
  let(:project) { Project.create(name: "test") }
  let(:private_subnet) { PrivateSubnet.create(project_id: project.id, name: "test", location_id: Location::HETZNER_FSN1_ID, net6: "fe80::/64", net4: "192.168.0.0/24") }
  let(:kubernetes_cluster) {
    KubernetesCluster.create(
      name: "test",
      version: "v1.32",
      cp_node_count: 3,
      private_subnet_id: private_subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      target_node_size: "standard-2"
    )
  }
  let(:session) { instance_double(Net::SSH::Connection::Session) }
  let(:kubernetes_client) { described_class.new(kubernetes_cluster, session) }

  describe "service_deleted?" do
    it "detects deleted service" do
      svc = {
        "metadata" => {
          "deletionTimestamp" => "asdf"
        }
      }
      expect(kubernetes_client.service_deleted?(svc)).to be(true)
    end

    it "detects not deleted service" do
      svc = {
        "metadata" => {}
      }
      expect(kubernetes_client.service_deleted?(svc)).to be(false)
    end
  end

  describe "lb_desired_ports" do
    it "returns desired ports sorted by creationTimestamp" do
      svc_list = [
        {
          "metadata" => {"name" => "svc-b", "namespace" => "default", "creationTimestamp" => "2024-01-03T00:00:00Z"},
          "spec" => {"ports" => [{"port" => 80, "nodePort" => 31942}, {"port" => 443, "nodePort" => 33212}]}
        },
        {
          "metadata" => {"name" => "svc-a", "namespace" => "default", "creationTimestamp" => "2024-01-01T00:00:00Z"},
          "spec" => {"ports" => [{"port" => 800, "nodePort" => 32942}]}
        }
      ]
      expect(kubernetes_client.lb_desired_ports(svc_list)).to eq([[800, 32942], [80, 31942], [443, 33212]])
    end

    it "keeps first occurrence of duplicate ports based on creationTimestamp" do
      svc_list = [
        {
          "metadata" => {"name" => "svc-newer", "namespace" => "default", "creationTimestamp" => "2024-01-02T00:00:00Z"},
          "spec" => {"ports" => [{"port" => 443, "nodePort" => 30123}]}
        },
        {
          "metadata" => {"name" => "svc-older", "namespace" => "default", "creationTimestamp" => "2024-01-01T00:00:00Z"},
          "spec" => {"ports" => [{"port" => 443, "nodePort" => 32003}]}
        }
      ]
      expect(kubernetes_client.lb_desired_ports(svc_list)).to eq([[443, 32003]])
    end

    it "returns empty list if no services have ports" do
      svc_list = [
        {"metadata" => {"name" => "svc0", "namespace" => "ns", "creationTimestamp" => "2024-01-01T00:00:00Z"}, "spec" => {}},
        {"metadata" => {"name" => "svc1", "namespace" => "ns", "creationTimestamp" => "2024-01-02T00:00:00Z"}, "spec" => {"ports" => nil}}
      ]
      expect(kubernetes_client.lb_desired_ports(svc_list)).to eq([])
    end

    it "ignores duplicate ports within the same service" do
      svc_list = [
        {
          "metadata" => {"name" => "svc0", "namespace" => "ns", "creationTimestamp" => "2024-01-01T00:00:00Z"},
          "spec" => {
            "ports" => [
              {"port" => 1234, "nodePort" => 30001},
              {"port" => 1234, "nodePort" => 30002}
            ]
          }
        }
      ]
      expect(kubernetes_client.lb_desired_ports(svc_list)).to eq([[1234, 30001]])
    end
  end

  describe "load_balancer_hostname_missing?" do
    it "returns false when hostname is present" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => [
              {"hostname" => "asdf.com"}
            ]
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(false)
    end

    it "returns true when ingress is an empty hash" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => {}
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end

    it "returns true when ingress is nil" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => nil
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end

    it "returns true when ingress is an empty array" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => []
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end

    it "returns true when hostname key is missing" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => [{}]
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end

    it "returns true when hostname is nil" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => [{"hostname" => nil}]
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end

    it "returns true when hostname is empty string" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => [{"hostname" => ""}]
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end

    it "returns false when hostname is present in the first ingress even if others are missing" do
      svc = {
        "status" => {
          "loadBalancer" => {
            "ingress" => [
              {"hostname" => "example.com"},
              {"hostname" => nil}
            ]
          }
        }
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(false)
    end

    it "returns true when loadBalancer key is missing" do
      svc = {
        "status" => {}
      }
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end

    it "returns true when status key is missing" do
      svc = {}
      expect(kubernetes_client.load_balancer_hostname_missing?(svc)).to be(true)
    end
  end

  describe "kubectl" do
    it "runs kubectl command in the right format" do
      expect(session).to receive(:exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes")
      kubernetes_client.kubectl("get nodes")
    end
  end

  describe "version" do
    it "runs a version command on kubectl" do
      expect(session).to receive(:exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf version --client").and_return("Client Version: v1.33.0\nKustomize Version: v5.6.0")
      expect(kubernetes_client.version).to eq("v1.33")
    end
  end

  describe "delete_node" do
    it "deletes a node" do
      expect(session).to receive(:exec!).with("sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf delete node asdf")
      kubernetes_client.delete_node("asdf")
    end
  end

  describe "set_load_balancer_hostname" do
    it "calls kubectl function with right inputs" do
      svc = {
        "metadata" => {
          "namespace" => "default",
          "name" => "test-svc"
        }
      }
      expect(kubernetes_client).to receive(:kubectl).with("-n default patch service test-svc --type=merge -p '{\"status\":{\"loadBalancer\":{\"ingress\":[{\"hostname\":\"asdf.com\"}]}}}' --subresource=status")
      kubernetes_client.set_load_balancer_hostname(svc, "asdf.com")
    end
  end

  describe "any_lb_services_modified?" do
    before do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 80, dst_port: 8000).subject
      kubernetes_cluster.update(services_lb: lb)
      @response = {
        "items" => ["metadata" => {"name" => "svc", "namespace" => "default", "creationTimestamp" => "2024-01-03T00:00:00Z"}]
      }.to_json
      allow(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(@response)
    end

    it "returns true early since there are no LoadBalancer services but there is a port" do
      response = {
        "items" => []
      }.to_json
      expect(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(response)
      expect(kubernetes_client.any_lb_services_modified?).to be(true)
    end

    it "determines lb_service is modified because vm_diff is not empty" do
      expect(kubernetes_cluster).to receive(:vm_diff_for_lb).and_return([[instance_double(Vm)], []])
      expect(kubernetes_client.any_lb_services_modified?).to be(true)

      expect(kubernetes_cluster).to receive(:vm_diff_for_lb).and_return([[], [instance_double(Vm)]])
      expect(kubernetes_client.any_lb_services_modified?).to be(true)
    end

    it "determines lb_service is modified because port_diff is not empty" do
      allow(kubernetes_cluster).to receive(:vm_diff_for_lb).and_return([[], []])

      expect(kubernetes_cluster).to receive(:port_diff_for_lb).and_return([[], [instance_double(LoadBalancerPort)]])
      expect(kubernetes_client.any_lb_services_modified?).to be(true)

      expect(kubernetes_cluster).to receive(:port_diff_for_lb).and_return([[instance_double(LoadBalancerPort)], []])
      expect(kubernetes_client.any_lb_services_modified?).to be(true)
    end

    it "determintes the modification because hostname is not set" do
      response = {
        "items" => [
          {
            "metadata" => {"name" => "svc", "namespace" => "default", "creationTimestamp" => "2024-01-03T00:00:00Z"},
            "status" => {
              "loadBalancer" => {
                "ingress" => [
                  {}
                ]
              }
            }
          }
        ]
      }.to_json
      expect(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(response)

      allow(kubernetes_cluster).to receive_messages(
        vm_diff_for_lb: [[], []],
        port_diff_for_lb: [[], []]
      )
      expect(kubernetes_client.any_lb_services_modified?).to be(true)
    end
  end

  describe "sync_kubernetes_services" do
    before do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(private_subnet.id, name: kubernetes_cluster.services_load_balancer_name, src_port: 80, dst_port: 8000).subject
      kubernetes_cluster.update(services_lb: lb)
      @response = {
        "items" => [
          "metadata" => {"name" => "svc", "namespace" => "default", "creationTimestamp" => "2024-01-03T00:00:00Z"}
        ]
      }.to_json
      allow(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return(@response)
    end

    it "reconciles with pre existing lb with not ready loadbalancer" do
      kubernetes_cluster.services_lb.strand.update(label: "not waiting")
      missing_port = [80, 8000]
      missing_vm = create_vm
      extra_vm = create_vm
      allow(kubernetes_client).to receive(:lb_desired_ports).and_return([[30122, 80]])
      allow(kubernetes_cluster).to receive_messages(
        vm_diff_for_lb: [[extra_vm], [missing_vm]],
        port_diff_for_lb: [[kubernetes_cluster.services_lb.ports.first], [missing_port]]
      )
      expect(kubernetes_client).not_to receive(:set_load_balancer_hostname)
      kubernetes_client.sync_kubernetes_services
    end

    it "reconciles with pre existing lb with ready loadbalancer" do
      missing_port = [80, 8000]
      missing_vm = create_vm
      extra_vm = create_vm
      allow(kubernetes_client).to receive(:lb_desired_ports).and_return([[30122, 80]])
      allow(kubernetes_cluster).to receive_messages(
        vm_diff_for_lb: [[extra_vm], [missing_vm]],
        port_diff_for_lb: [[kubernetes_cluster.services_lb.ports.first], [missing_port]]
      )
      expect(kubernetes_client).to receive(:set_load_balancer_hostname)
      kubernetes_client.sync_kubernetes_services
    end

    it "raises error with non existing lb" do
      kubernetes_client = described_class.new(instance_double(KubernetesCluster, services_lb: nil), instance_double(Net::SSH::Connection::Session))
      allow(kubernetes_client).to receive(:kubectl).with("get service --all-namespaces --field-selector spec.type=LoadBalancer -ojson").and_return({"items" => [{}]}.to_json)
      expect { kubernetes_client.sync_kubernetes_services }.to raise_error("services load balancer does not exist.")
    end
  end
end
