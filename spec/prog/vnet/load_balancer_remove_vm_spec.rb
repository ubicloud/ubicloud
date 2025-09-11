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

  describe "#remove_vm" do
    it "removes the vm from load balancer and hops to wait_remove_vm" do
      expect(lb).to receive(:vm_ports_by_vm).with(vm).and_return(instance_double(LoadBalancerPort, destroy: nil)).at_least(:once)
      expect(lb.vm_ports_by_vm(vm)).to receive(:destroy)
      expect(nx).to receive(:bud).with(Prog::Vnet::UpdateLoadBalancerNode, {subject_id: lb.id, vm_id: vm.id}, :remove_vm)
      expect { nx.remove_vm }.to hop("wait_remove_vm")
    end
  end

  describe "#wait_remove_vm" do
    it "reaps the remove_cert_server and hops to evacuate_vm" do
      expect { nx.wait_remove_vm }.to hop("remove_cert_server")
    end
  end

  describe "#evacuate_vm" do
    it "evacuates the vm and hops to remove_cert_server" do
      vm_port = instance_double(LoadBalancerVmPort)
      expect(lb).to receive(:vm_ports_by_vm_and_state).with(vm, ["up", "down"]).and_return(vm_port).at_least(:once)
      expect(vm_port).to receive(:update).with(state: "evacuating")
      expect { nx.evacuate_vm }.to hop("remove_cert_server")
    end
  end

  describe "#remove_cert_server" do
    it "removes the certificate server and hops to wait_remove_cert_server" do
      expect(lb).to receive(:cert_enabled_lb?).and_return(true)
      expect(nx).to receive(:bud).with(Prog::Vnet::CertServer, {subject_id: lb.id, vm_id: vm.id}, :remove_cert_server)
      expect { nx.remove_cert_server }.to hop("wait_remove_cert_server")
    end

    it "hops to wait_remove_cert_server if cert_enabled_lb? is false" do
      expect(lb).to receive(:cert_enabled_lb?).and_return(false)
      expect(nx).not_to receive(:bud)
      expect { nx.remove_cert_server }.to hop("wait_remove_cert_server")
    end
  end

  describe "#wait_remove_cert_server" do
    it "reaps the cleanup_vm and hops to evacuate_vm" do
      expect { nx.wait_remove_cert_server }.to hop("cleanup_vm")
    end
  end

  describe "#cleanup_vm" do
    it "removes the vm from load balancer and hops to evacuate_vm" do
      expect(lb).to receive(:vm_ports_by_vm).with(vm).and_return(instance_double(LoadBalancerPort, destroy: nil)).at_least(:once)
      expect(lb.vm_ports_by_vm(vm)).to receive(:destroy)
      expect(lb).to receive(:incr_update_load_balancer)
      expect(lb).to receive(:incr_rewrite_dns_records)
      dataset = instance_double(Sequel::Dataset)
      expect(lb).to receive(:load_balancer_vms_dataset).and_return(dataset)
      expect(dataset).to receive(:where).with(vm_id: vm.id).and_return(instance_double(LoadBalancerVm, destroy: nil))
      expect { nx.cleanup_vm }.to exit({"msg" => "vm is removed from load balancer"})
    end
  end
end
