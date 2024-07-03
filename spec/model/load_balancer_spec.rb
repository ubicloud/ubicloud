# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe LoadBalancer do
  subject(:lb) {
    prj = Project.create_with_id(name: "test-prj").tap { _1.associate_with_project(_1) }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps")
    Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 80).subject
  }

  let(:vm1) {
    prj = lb.private_subnet.projects.first
    Prog::Vm::Nexus.assemble("pub-key", prj.id, name: "test-vm1", private_subnet_id: lb.private_subnet.id).subject
  }

  describe "util funcs" do
    before do
      allow(Config).to receive(:load_balancer_service_hostname).and_return("lb.ubicloud.com")
    end

    it "returns hyper_tag_name" do
      prj = lb.private_subnet.projects.first
      expect(lb.hyper_tag_name(prj)).to eq("project/#{prj.ubid}/location/eu-north-h1/load-balancer/test-lb")
    end

    it "returns hostname" do
      expect(lb.hostname).to eq("test-lb.#{lb.ubid[-5...]}.lb.ubicloud.com")
    end
  end

  describe "add_vm" do
    it "increments update_load_balancer and rewrite_dns_records" do
      expect(lb).to receive(:incr_update_load_balancer)
      expect(lb).to receive(:incr_rewrite_dns_records)
      lb.add_vm(vm1)
      expect(lb.load_balancers_vms.count).to eq(1)
    end
  end

  describe "evacuate_vm" do
    before do
      lb.add_vm(vm1)
    end

    it "increments update_load_balancer and rewrite_dns_records" do
      expect(lb).to receive(:incr_update_load_balancer)
      expect(lb).to receive(:incr_rewrite_dns_records)
      health_probe = instance_double(Strand, stack: [{"subject_id" => lb.id, "vm_id" => vm1.id}])
      expect(lb.strand).to receive(:children_dataset).and_return(instance_double(Sequel::Dataset, where: instance_double(Sequel::Dataset, all: [health_probe])))
      expect(health_probe).to receive(:destroy)
      lb.evacuate_vm(vm1)
      expect(lb.load_balancers_vms.first[:state]).to eq("evacuating")
    end
  end

  describe "remove_vm" do
    before do
      lb.add_vm(vm1)
    end

    it "deletes the vm" do
      lb.remove_vm(vm1)
      expect(lb.load_balancers_vms.count).to eq(0)
    end
  end
end
