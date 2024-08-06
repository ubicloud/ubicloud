# frozen_string_literal: true

RSpec.describe Prog::Vnet::LoadBalancerHealthProbes do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    Strand.create_with_id(prog: "Vnet::LoadBalancerHealthProbes", stack: [{"subject_id" => lb.id, "vm_id" => vm.id}], label: "health_probe")
  }
  let(:lb) {
    prj = Project.create_with_id(name: "test-prj").tap { _1.associate_with_project(_1) }
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
    Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 80).subject
  }
  let(:vm) {
    Prog::Vm::Nexus.assemble("pub-key", lb.projects.first.id, name: "test-vm", private_subnet_id: lb.private_subnet.id).subject
  }

  before do
    allow(nx).to receive_messages(load_balancer: lb)
  end

  describe "#health_probe" do
    let(:vmh) {
      instance_double(VmHost, sshable: instance_double(Sshable))
    }

    before do
      allow(vm).to receive(:vm_host).and_return(vmh)
      lb.add_vm(vm)
      lb.load_balancers_vms_dataset.update(state: "up")
      expect(Vm).to receive(:[]).with(vm.id).and_return(vm)
      expect(vm.nics.first).to receive(:private_ipv4).and_return(NetAddr::IPv4Net.parse("192.168.1.0"))
    end

    it "naps for 5 seconds and doesn't perform update if health check succeeds" do
      expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} curl --insecure --max-time 15 --silent --output /dev/null --write-out '%{http_code}' http://192.168.1.0:80/up").and_return("200")
      expect(lb).not_to receive(:incr_update_load_balancer)

      expect { nx.health_probe }.to nap(30)
    end

    it "naps for 5 seconds and doesn't perform update if health check fails the first time" do
      lb.load_balancers_vms_dataset.update(state_counter: 1)
      expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} curl --insecure --max-time 15 --silent --output /dev/null --write-out '%{http_code}' http://192.168.1.0:80/up").and_return("500")
      expect(lb).not_to receive(:incr_update_load_balancer)

      expect { nx.health_probe }.to nap(30)
    end

    it "naps for 5 seconds and performs update if health check fails the first time via an exception" do
      lb.load_balancers_vms_dataset.update(state_counter: 1)
      expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} curl --insecure --max-time 15 --silent --output /dev/null --write-out '%{http_code}' http://192.168.1.0:80/up").and_raise("error")
      expect(lb).not_to receive(:incr_update_load_balancer)

      expect { nx.health_probe }.to nap(30)
    end

    it "starts update if health check succeeds and we hit the threshold" do
      lb.load_balancers_vms_dataset.update(state_counter: 2)
      expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} curl --insecure --max-time 15 --silent --output /dev/null --write-out '%{http_code}' http://192.168.1.0:80/up").and_return("200")
      expect(lb).to receive(:incr_update_load_balancer)

      expect { nx.health_probe }.to nap(30)
    end

    it "naps for 5 seconds and doesn't perform update if health check succeeds and we're already above threshold" do
      lb.load_balancers_vms_dataset.update(state_counter: 3)
      expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} curl --insecure --max-time 15 --silent --output /dev/null --write-out '%{http_code}' http://192.168.1.0:80/up").and_return("200")
      expect(lb).not_to receive(:incr_update_load_balancer)

      expect { nx.health_probe }.to nap(30)
    end

    it "uses nc for tcp health checks" do
      lb.update(health_check_protocol: "tcp")
      expect(vmh.sshable).to receive(:cmd).with("sudo ip netns exec #{vm.inhost_name} nc -z -w 15 192.168.1.0 80 && echo 200 || echo 400").and_return("200")
      expect(lb).not_to receive(:incr_update_load_balancer)

      expect { nx.health_probe }.to nap(30)
    end
  end
end
