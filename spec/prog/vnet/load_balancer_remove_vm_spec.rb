# frozen_string_literal: true

RSpec.describe Prog::Vnet::LoadBalancerRemoveVm do
  subject(:nx) {
    described_class.new(st)
  }

  let(:prj) { Project.create(name: "test-prj") }
  let(:ps) { Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject }
  let(:lb) { Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080).subject }

  let(:vm) {
    v = Prog::Vm::Nexus.assemble_with_sshable(prj.id, name: "lb-vm", private_subnet_id: ps.id, unix_user: "ubi").subject
    lb.add_vm(v)
    v
  }

  let(:st) {
    Strand.create(prog: "Vnet::LoadBalancerRemoveVm", stack: [{"subject_id" => vm.id}], label: "remove_vm")
  }

  describe "#before_run" do
    it "pops if the vm is not found" do
      st_no_vm = Strand.create(prog: "Vnet::LoadBalancerRemoveVm", stack: [{"subject_id" => Vm.generate_uuid}], label: "remove_vm")
      nx_no_vm = described_class.new(st_no_vm)
      expect { nx_no_vm.before_run }.to exit({"msg" => "vm is removed from load balancer"})
    end

    it "pops if the vm exists but the load balancer reference is nil" do
      vm_no_lb = Prog::Vm::Nexus.assemble_with_sshable(prj.id, name: "vm-no-lb", private_subnet_id: ps.id, unix_user: "ubi").subject
      st_no_lb = Strand.create(prog: "Vnet::LoadBalancerRemoveVm", stack: [{"subject_id" => vm_no_lb.id}], label: "remove_vm")
      nx_no_lb = described_class.new(st_no_lb)
      expect { nx_no_lb.before_run }.to exit({"msg" => "vm is removed from load balancer"})
    end

    it "does nothing if the vm exists and the load balancer reference is not nil" do
      expect { nx.before_run }.not_to exit
    end
  end

  describe "#destroy_vm_ports_and_update_node" do
    it "removes the vm from load balancer and hops to wait_for_node_update" do
      vm_port_count = lb.vm_ports_by_vm(vm).count
      expect(vm_port_count).to be > 0
      expect { nx.destroy_vm_ports_and_update_node }.to hop("wait_for_node_update")
      expect(lb.reload.vm_ports_by_vm(vm).count).to eq(0)
      expect(st.children_dataset.where(prog: "Vnet::UpdateLoadBalancerNode", label: "update_load_balancer").count).to eq 1
    end
  end

  describe "#wait_for_node_update" do
    it "reaps the wait_for_node_update and hops to initiate_cert_server_removal" do
      expect { nx.wait_for_node_update }.to hop("initiate_cert_server_removal")
    end
  end

  describe "#mark_vm_ports_as_evacuating" do
    it "evacuates the vm and hops to remove_cert_server" do
      lb.vm_ports_by_vm(vm).update(state: "up")
      expect(lb.vm_ports_by_vm_and_state(vm, ["up", "down"]).count).to be > 0
      expect { nx.mark_vm_ports_as_evacuating }.to hop("initiate_cert_server_removal")
      expect(lb.reload.vm_ports_by_vm_and_state(vm, ["evacuating"]).count).to be > 0
    end
  end

  describe "#initiate_cert_server_removal" do
    it "removes the certificate server and hops to wait_for_cert_server_removal" do
      lb.update(cert_enabled: true)
      expect { nx.initiate_cert_server_removal }.to hop("wait_for_cert_server_removal")
      expect(st.children_dataset.where(prog: "Vnet::CertServer", label: "remove_cert_server").count).to eq 1
    end

    it "hops to wait_for_cert_server_removal if cert_enabled is false" do
      lb.update(cert_enabled: false)
      expect { nx.initiate_cert_server_removal }.to hop("wait_for_cert_server_removal")
      expect(st.children_dataset.where(prog: "Vnet::CertServer").count).to eq 0
    end
  end

  describe "#wait_for_cert_server_removal" do
    it "reaps the wait_for_cert_server_removal and hops to finalize_vm_removal" do
      expect { nx.wait_for_cert_server_removal }.to hop("finalize_vm_removal")
    end
  end

  describe "#finalize_vm_removal" do
    it "removes the vm from load balancer and exits" do
      expect(lb.load_balancer_vms_dataset.where(vm_id: vm.id).count).to eq(1)
      expect { nx.finalize_vm_removal }.to exit({"msg" => "vm is removed from load balancer"})

      lb.reload
      expect(lb.vm_ports_by_vm(vm).count).to eq(0)
      expect(lb.load_balancer_vms_dataset.where(vm_id: vm.id).count).to eq(0)
      expect(lb.update_load_balancer_set?).to be true
      expect(lb.rewrite_dns_records_set?).to be true
    end
  end
end
