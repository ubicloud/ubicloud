# frozen_string_literal: true

RSpec.describe Prog::Vnet::PrivatelinkAwsVmNexus do
  subject(:nx) { described_class.new(pl_vm.strand) }

  let(:ps) {
    prj = Project.create(name: "test-prj")
    loc = Location.create(name: "us-east-1", provider: "aws", project_id: prj.id, display_name: "us-east-1", ui_name: "AWS US East 1", visible: true)
    LocationCredential.create_with_id(loc.id, access_key: "stubbed-akid", secret_key: "stubbed-secret")
    az_a = LocationAwsAz.create(location_id: loc.id, az: "a", zone_id: "use1-az1")
    ps = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps", location_id: loc.id).subject
    ps.private_subnet_aws_resource.update(
      vpc_id: "vpc-0123456789abcdefg",
      internet_gateway_id: "igw-0123456789abcdefg",
      route_table_id: "rtb-0123456789abcdefg",
      security_group_id: "sg-0123456789abcdefg"
    )
    aws_subnet = AwsSubnet.where(private_subnet_aws_resource_id: ps.private_subnet_aws_resource.id, location_aws_az_id: az_a.id).first
    aws_subnet.update(subnet_id: "subnet-0123456789abcdefg", ipv6_cidr: "2600:1f14:1000::/64")
    ps
  }

  let(:location) { ps.location }

  let(:nic) {
    nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
    NicAwsResource.create_with_id(nic.id, subnet_id: "subnet-0123456789abcdefg", subnet_az: "us-east-1a")
    nic
  }

  let(:vm) {
    nic  # ensure nic exists before creating vm
    vm = create_hosted_vm(ps.project, ps, "test-vm")
    vm.nics.find { it.private_subnet_id == ps.id }.update(private_ipv4: "10.0.0.5/32")
    vm
  }

  let(:pl) {
    nic  # ensure nic exists before assembling
    Prog::Vnet::PrivatelinkAwsNexus.assemble(private_subnet_id: ps.id).subject
  }

  let(:pl_vm) {
    vm  # ensure vm exists
    pl_vm = PrivatelinkAwsVm.create(privatelink_aws_resource_id: pl.id, vm_id: vm.id)
    Strand.create_with_id(pl_vm, prog: "Vnet::PrivatelinkAwsVmNexus", label: "start")
    pl_vm
  }

  let(:elb_client) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }

  before do
    allow(Aws::ElasticLoadBalancingV2::Client).to receive(:new).with(credentials: anything, region: "us-east-1").and_return(elb_client)
  end

  describe "#start" do
    it "creates vm_ports in registering state and hops to wait" do
      expect { nx.start }.to hop("wait")
        .and change { pl_vm.vm_ports_dataset.where(state: "registering").count }.from(0).to(1)
    end
  end

  describe "#wait" do
    it "naps by default" do
      expect { nx.wait }.to nap(30)
    end

    it "hops to add_port when semaphore is set" do
      nx.incr_add_port
      expect { nx.wait }.to hop("add_port")
    end
  end

  describe "#add_port" do
    before {
      pl.ports.first.update(target_group_arn: "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/pl-tg/abc")
      PrivatelinkAwsVmPort.create(
        privatelink_aws_vm_id: pl_vm.id,
        privatelink_aws_port_id: pl.ports.first.id,
        state: "registering"
      )
      nx.incr_add_port
      elb_client.stub_responses(:register_targets)
    }

    it "registers registering vm_ports and hops to wait" do
      expect { nx.add_port }.to hop("wait")
        .and change { pl_vm.vm_ports_dataset.where(state: "registered").count }.from(0).to(1)
    end

    it "naps to retry if target group not found in AWS" do
      elb_client.stub_responses(:register_targets, Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound.new(nil, nil))
      expect { nx.add_port }.to nap(5)
    end

    it "naps to retry if port has no target_group_arn" do
      pl.ports.first.update(target_group_arn: nil)
      expect(elb_client).not_to receive(:register_targets)
      expect { nx.add_port }.to nap(5)
    end

    it "naps to retry if vm has no NIC in subnet" do
      vm.nics.find { it.private_subnet_id == ps.id }.update(private_subnet_id: Prog::Vnet::SubnetNexus.assemble(ps.project.id, name: "other-ps", location_id: ps.location.id).subject.id)
      expect(elb_client).not_to receive(:register_targets)
      expect { nx.add_port }.to nap(5)
    end
  end

  describe "#destroy" do
    before {
      pl.ports.first.update(target_group_arn: "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/pl-tg/abc")
      PrivatelinkAwsVmPort.create(
        privatelink_aws_vm_id: pl_vm.id,
        privatelink_aws_port_id: pl.ports.first.id,
        state: "registered"
      )
      nx.incr_destroy
      elb_client.stub_responses(:deregister_targets)
    }

    it "deregisters targets, destroys pl_vm, and pops" do
      expect { nx.destroy }.to exit({"msg" => "PrivatelinkAwsVm destroyed"})
      expect(PrivatelinkAwsVm[pl_vm.id]).to be_nil
    end

    it "handles already-deregistered target gracefully" do
      elb_client.stub_responses(:deregister_targets, Aws::ElasticLoadBalancingV2::Errors::TargetNotRegisteredException.new(nil, nil))
      expect { nx.destroy }.to exit({"msg" => "PrivatelinkAwsVm destroyed"})
    end

    it "handles target group not found gracefully" do
      elb_client.stub_responses(:deregister_targets, Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound.new(nil, nil))
      expect { nx.destroy }.to exit({"msg" => "PrivatelinkAwsVm destroyed"})
    end

    it "skips deregistration if port has no target_group_arn" do
      pl.ports.first.update(target_group_arn: nil)
      expect(elb_client).not_to receive(:deregister_targets)
      expect { nx.destroy }.to exit({"msg" => "PrivatelinkAwsVm destroyed"})
    end

    it "skips deregistration if vm has no NIC in subnet" do
      vm.nics.find { it.private_subnet_id == ps.id }.update(private_subnet_id: Prog::Vnet::SubnetNexus.assemble(ps.project.id, name: "other-ps", location_id: ps.location.id).subject.id)
      expect(elb_client).not_to receive(:deregister_targets)
      expect { nx.destroy }.to exit({"msg" => "PrivatelinkAwsVm destroyed"})
    end
  end

  describe "#before_run" do
    it "hops to destroy when destroy semaphore is set" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).at_least(:once).and_return("wait")
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end
end
