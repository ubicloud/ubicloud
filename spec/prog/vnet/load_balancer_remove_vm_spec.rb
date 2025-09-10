# frozen_string_literal: true

RSpec.describe Prog::Vnet::LoadBalancerRemoveVm do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create(prog: "Vnet::LoadBalancerRemoveVm", stack: [{"subject_id" => lb.id, "vm_id" => vm.id}], label: "remove_vm")
  }

  let(:lb) {
    prj = Project.create(name: "test-prj")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
    lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080).subject
    lb
  }

  let(:vm) {
    instance_double(Vm, inhost_name: "test-vm", id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e", load_balancer: lb)
  }

  before do
    allow(Vm).to receive(:[]).and_return(vm)
  end

  describe "#destroy_vm_ports_and_update_node" do
    it "removes the vm from load balancer and hops to wait_for_node_update" do
      expect(lb).to receive(:vm_ports_by_vm).with(vm).and_return(instance_double(LoadBalancerPort, destroy: nil)).at_least(:once)
      expect(lb.vm_ports_by_vm(vm)).to receive(:destroy)
      expect(nx).to receive(:bud).with(Prog::Vnet::UpdateLoadBalancerNode, {subject_id: vm.id, load_balancer_id: lb.id}, :update_load_balancer)
      expect { nx.destroy_vm_ports_and_update_node }.to hop("wait_for_node_update")
    end
  end

  describe "#wait_for_node_update" do
    it "reaps the wait_for_node_update and hops to initiate_cert_server_removal" do
      expect { nx.wait_for_node_update }.to hop("initiate_cert_server_removal")
    end
  end

  describe "#mark_vm_ports_as_evacuating" do
    it "evacuates the vm and hops to remove_cert_server" do
      vm_port = instance_double(LoadBalancerVmPort)
      expect(lb).to receive(:vm_ports_by_vm_and_state).with(vm, ["up", "down"]).and_return(vm_port).at_least(:once)
      expect(vm_port).to receive(:update).with(state: "evacuating")
      expect { nx.mark_vm_ports_as_evacuating }.to hop("initiate_cert_server_removal")
    end
  end

  describe "#initiate_cert_server_removal" do
    it "removes the certificate server and hops to wait_for_cert_server_removal" do
      expect(lb).to receive(:cert_enabled_lb?).and_return(true)
      expect(nx).to receive(:bud).with(Prog::Vnet::CertServer, {subject_id: lb.id, vm_id: vm.id}, :remove_cert_server)
      expect { nx.initiate_cert_server_removal }.to hop("wait_for_cert_server_removal")
    end

    it "hops to wait_for_cert_server_removal if cert_enabled_lb? is false" do
      expect(lb).to receive(:cert_enabled_lb?).and_return(false)
      expect(nx).not_to receive(:bud)
      expect { nx.initiate_cert_server_removal }.to hop("wait_for_cert_server_removal")
    end
  end

  describe "#wait_for_cert_server_removal" do
    it "reaps the wait_for_cert_server_removal and hops to finalize_vm_removal" do
      expect { nx.wait_for_cert_server_removal }.to hop("finalize_vm_removal")
    end
  end

  describe "#finalize_vm_removal" do
    it "removes the vm from load balancer and exits" do
      expect(lb).to receive(:vm_ports_by_vm).with(vm).and_return(instance_double(LoadBalancerPort, destroy: nil)).at_least(:once)
      expect(lb.vm_ports_by_vm(vm)).to receive(:destroy)
      expect(lb).to receive(:incr_update_load_balancer)
      expect(lb).to receive(:incr_rewrite_dns_records)
      dataset = instance_double(Sequel::Dataset)
      expect(lb).to receive(:load_balancer_vms_dataset).and_return(dataset)
      expect(dataset).to receive(:where).with(vm_id: vm.id).and_return(instance_double(LoadBalancerVm, destroy: nil))
      expect { nx.finalize_vm_removal }.to exit({"msg" => "vm is removed from load balancer"})
    end
  end
end
