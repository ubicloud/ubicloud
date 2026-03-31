# frozen_string_literal: true

RSpec.describe Prog::Vnet::PrivatelinkAwsNexus do
  subject(:nx) { described_class.new(pl.strand) }

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

  let(:nic) {
    nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "test-nic").subject
    NicAwsResource.create_with_id(nic.id, subnet_id: "subnet-0123456789abcdefg", subnet_az: "us-east-1a")
    nic
  }

  let(:pl) {
    nic  # ensure nic exists before assembling
    described_class.assemble(private_subnet_id: ps.id).subject
  }

  let(:location) { ps.location }
  let(:elb_client) { Aws::ElasticLoadBalancingV2::Client.new(stub_responses: true) }
  let(:ec2_client) { Aws::EC2::Client.new(stub_responses: true) }

  before do
    allow(Aws::ElasticLoadBalancingV2::Client).to receive(:new).with(credentials: anything, region: "us-east-1").and_return(elb_client)
    allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-east-1").and_return(ec2_client)
  end

  describe ".assemble" do
    it "fails if private subnet does not exist" do
      expect { described_class.assemble(private_subnet_id: "00000000-0000-0000-0000-000000000000") }.to raise_error("No existing private subnet")
    end

    it "fails if location is not AWS" do
      non_aws_loc = Location.create(name: "fsn1", provider: "hetzner", project_id: ps.project.id, display_name: "fsn1", ui_name: "Falkenstein", visible: true)
      non_aws_ps = Prog::Vnet::SubnetNexus.assemble(ps.project.id, name: "non-aws-ps", location_id: non_aws_loc.id).subject
      expect { described_class.assemble(private_subnet_id: non_aws_ps.id) }.to raise_error("PrivateLink is only supported on AWS")
    end

    it "fails if PrivateLink already exists for subnet" do
      pl  # force creation
      expect { described_class.assemble(private_subnet_id: ps.id) }.to raise_error(CloverError) do |e|
        expect(e.code).to eq(409)
      end
    end

    it "creates PrivatelinkAwsResource, ports, and strand" do
      strand = described_class.assemble(private_subnet_id: ps.id, ports: [[5432, 5432], [6432, 5432]], description: "test PL")
      pl = strand.subject
      expect(pl).to be_a(PrivatelinkAwsResource)
      expect(pl.description).to eq("test PL")
      expect(pl.ports.map { [it.src_port, it.dst_port] }).to contain_exactly([5432, 5432], [6432, 5432])
      expect(strand.label).to eq("start")
    end

    it "uses a default description if none given" do
      strand = described_class.assemble(private_subnet_id: ps.id)
      expect(strand.subject.description).to include(ps.name)
    end
  end

  describe "#start" do
    it "creates an NLB and hops to wait_nlb_active" do
      nlb_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/pl-test/abc123"
      elb_client.stub_responses(:create_load_balancer, load_balancers: [{load_balancer_arn: nlb_arn}])
      expect { nx.start }.to hop("wait_nlb_active")
        .and change { pl.reload.nlb_arn }.from(nil).to(nlb_arn)
    end

    it "naps if no NIC with AWS resources exists in the subnet" do
      nic.nic_aws_resource.destroy
      nic.reload
      expect { nx.start }.to nap(10)
    end
  end

  describe "#wait_nlb_active" do
    before { pl.update(nlb_arn: "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/net/pl-test/abc") }

    it "naps if NLB is not yet active" do
      elb_client.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "provisioning"}}])
      expect { nx.wait_nlb_active }.to nap(5)
    end

    it "hops to create_target_groups_and_listeners when NLB is active" do
      elb_client.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "active"}}])
      expect { nx.wait_nlb_active }.to hop("create_target_groups_and_listeners")
    end
  end

  describe "#create_target_groups_and_listeners" do
    before {
      pl.update(nlb_arn: "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/net/pl-test/abc")
      elb_client.stub_responses(:create_target_group, target_groups: [{target_group_arn: "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/pl-tg/abc"}])
      elb_client.stub_responses(:create_listener, listeners: [{listener_arn: "arn:aws:elasticloadbalancing:us-east-1:123:listener/net/pl-test/abc/def"}])
    }

    it "creates a target group and listener for each port, signals vm strands, then hops to create_endpoint_service" do
      expect { nx.create_target_groups_and_listeners }.to hop("create_endpoint_service")
      port = pl.ports.first.reload
      expect(port.target_group_arn).to eq("arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/pl-tg/abc")
      expect(port.listener_arn).to eq("arn:aws:elasticloadbalancing:us-east-1:123:listener/net/pl-test/abc/def")
    end

    it "signals vm strands with add_port if they exist" do
      pl_vm = PrivatelinkAwsVm.create(privatelink_aws_resource_id: pl.id, vm_id: create_hosted_vm(ps.project, ps, "test-vm").id)
      Strand.create_with_id(pl_vm, prog: "Vnet::PrivatelinkAwsVmNexus", label: "wait")
      expect { nx.create_target_groups_and_listeners }.to hop("create_endpoint_service")
      expect(pl_vm.strand.reload.semaphores.map(&:name)).to include("add_port")
    end
  end

  describe "#create_endpoint_service" do
    before { pl.update(nlb_arn: "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/net/pl-test/abc") }

    it "creates endpoint service and hops to wait" do
      ec2_client.stub_responses(:create_vpc_endpoint_service_configuration, service_configuration: {
        service_name: "com.amazonaws.vpce.us-east-1.vpce-svc-0abc123",
        service_id: "vpce-svc-0abc123"
      })
      expect { nx.create_endpoint_service }.to hop("wait")
        .and change { pl.reload.service_name }.from(nil).to("com.amazonaws.vpce.us-east-1.vpce-svc-0abc123")
        .and change { pl.reload.service_id }.from(nil).to("vpce-svc-0abc123")
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

    it "hops to remove_port when semaphore is set" do
      nx.incr_remove_port
      expect { nx.wait }.to hop("remove_port")
    end
  end

  describe "#remove_port" do
    let(:vm) {
      vm = create_hosted_vm(ps.project, ps, "test-vm")
      vm.nics.find { it.private_subnet_id == ps.id }.update(private_ipv4: "10.0.0.5/32")
      vm
    }
    let(:pl_vm) { PrivatelinkAwsVm.create(privatelink_aws_resource_id: pl.id, vm_id: vm.id) }

    before {
      pl.update(nlb_arn: "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/net/pl-test/abc")
      pl.ports.first.update(
        target_group_arn: "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/pl-tg/abc",
        listener_arn: "arn:aws:elasticloadbalancing:us-east-1:123:listener/net/pl-test/abc/def"
      )
      PrivatelinkAwsVmPort.create(
        privatelink_aws_vm_id: pl_vm.id,
        privatelink_aws_port_id: pl.ports.first.id,
        state: "deregistering"
      )
      nx.incr_remove_port
      elb_client.stub_responses(:deregister_targets)
      elb_client.stub_responses(:delete_listener)
      elb_client.stub_responses(:delete_target_group)
    }

    it "deregisters targets, deletes listener and target group, destroys port, and hops to wait" do
      port_id = pl.ports.first.id
      expect { nx.remove_port }.to hop("wait")
      expect(PrivatelinkAwsPort[port_id]).to be_nil
      expect(PrivatelinkAwsVmPort.where(privatelink_aws_port_id: port_id).count).to eq(0)
    end

    it "uses a single query to load vm_ports regardless of port count" do
      port2 = PrivatelinkAwsPort.create(
        privatelink_aws_resource_id: pl.id, src_port: 6432, dst_port: 5432,
        target_group_arn: "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/pl-tg/def",
        listener_arn: "arn:aws:elasticloadbalancing:us-east-1:123:listener/net/pl-test/abc/ghi"
      )
      PrivatelinkAwsVmPort.create(
        privatelink_aws_vm_id: pl_vm.id,
        privatelink_aws_port_id: port2.id,
        state: "deregistering"
      )

      counter = Struct.new(:n) do
        def info(sql)
          # Strip Sequel's "(0.000000s) " timing prefix, then check if
          # privatelink_aws_vm_port is the primary FROM table (not in a subquery)
          pure = sql.sub(/\A\([0-9.]+s\)\s+/, "")
          self.n += 1 if pure.start_with?('SELECT * FROM "privatelink_aws_vm_port"')
        end
        def debug(_); end
        def warn(_); end
        def error(_); end
      end.new(0)

      DB.loggers << counter
      begin
        expect { nx.remove_port }.to hop("wait")
      ensure
        DB.loggers.delete(counter)
      end

      expect(counter.n).to eq(1)
    end

    it "handles TargetNotRegisteredException gracefully" do
      elb_client.stub_responses(:deregister_targets,
        Aws::ElasticLoadBalancingV2::Errors::TargetNotRegisteredException.new(nil, nil))
      expect { nx.remove_port }.to hop("wait")
    end

    it "handles TargetGroupNotFound gracefully" do
      elb_client.stub_responses(:deregister_targets,
        Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound.new(nil, nil))
      expect { nx.remove_port }.to hop("wait")
    end

    it "skips deregistration if vm is not in the subnet" do
      other_ps = Prog::Vnet::SubnetNexus.assemble(ps.project.id, name: "other-ps", location_id: ps.location.id).subject
      vm.nics.find { it.private_subnet_id == ps.id }.update(private_subnet_id: other_ps.id)
      expect(elb_client).not_to receive(:deregister_targets)
      expect { nx.remove_port }.to hop("wait")
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

    it "does not hop to destroy if already in wait_nlb_deletion state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("wait_nlb_deletion")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#destroy" do
    before {
      pl.update(
        nlb_arn: "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/net/pl-test/abc",
        service_id: "vpce-svc-0abc123"
      )
      pl.ports.first.update(
        target_group_arn: "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/pl-tg/abc",
        listener_arn: "arn:aws:elasticloadbalancing:us-east-1:123:listener/net/pl-test/abc/def"
      )
      nx.incr_destroy
    }

    it "naps while vm strands are still running" do
      pl_vm = PrivatelinkAwsVm.create(privatelink_aws_resource_id: pl.id, vm_id: create_hosted_vm(ps.project, ps, "test-vm").id)
      Strand.create_with_id(pl_vm, prog: "Vnet::PrivatelinkAwsVmNexus", label: "wait")
      expect { nx.destroy }.to nap(5)
      expect(pl_vm.strand.reload.semaphores.map(&:name)).to include("destroy")
    end

    it "destroys a vm directly if it has no strand" do
      pl_vm = PrivatelinkAwsVm.create(privatelink_aws_resource_id: pl.id, vm_id: create_hosted_vm(ps.project, ps, "test-vm").id)
      ec2_client.stub_responses(:delete_vpc_endpoint_service_configurations)
      ec2_client.stub_responses(:describe_vpc_endpoint_service_configurations,
        Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound.new(nil, nil))
      elb_client.stub_responses(:delete_listener)
      elb_client.stub_responses(:delete_target_group)
      elb_client.stub_responses(:delete_load_balancer)
      expect { nx.destroy }.to hop("wait_nlb_deletion")
      expect(PrivatelinkAwsVm[pl_vm.id]).to be_nil
    end

    it "deletes endpoint service, TG, listener, NLB and hops to wait_nlb_deletion" do
      ec2_client.stub_responses(:delete_vpc_endpoint_service_configurations)
      ec2_client.stub_responses(:describe_vpc_endpoint_service_configurations,
        Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound.new(nil, nil))
      elb_client.stub_responses(:delete_listener)
      elb_client.stub_responses(:delete_target_group)
      elb_client.stub_responses(:delete_load_balancer)
      expect { nx.destroy }.to hop("wait_nlb_deletion")
    end

    it "handles already-deleted endpoint service gracefully" do
      ec2_client.stub_responses(:delete_vpc_endpoint_service_configurations,
        Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound.new(nil, nil))
      ec2_client.stub_responses(:describe_vpc_endpoint_service_configurations,
        Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound.new(nil, nil))
      elb_client.stub_responses(:delete_listener)
      elb_client.stub_responses(:delete_target_group)
      elb_client.stub_responses(:delete_load_balancer)
      expect { nx.destroy }.to hop("wait_nlb_deletion")
    end

    it "naps if endpoint service still exists after delete" do
      ec2_client.stub_responses(:delete_vpc_endpoint_service_configurations)
      ec2_client.stub_responses(:describe_vpc_endpoint_service_configurations,
        service_configurations: [{service_id: "vpce-svc-0abc123", service_state: "Deleting"}])
      expect { nx.destroy }.to nap(10)
    end

    it "naps if NLB is still in use by endpoint service" do
      ec2_client.stub_responses(:delete_vpc_endpoint_service_configurations)
      ec2_client.stub_responses(:describe_vpc_endpoint_service_configurations,
        Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound.new(nil, nil))
      elb_client.stub_responses(:delete_listener)
      elb_client.stub_responses(:delete_target_group)
      elb_client.stub_responses(:delete_load_balancer,
        Aws::ElasticLoadBalancingV2::Errors::ResourceInUse.new(nil, nil))
      expect { nx.destroy }.to nap(10)
    end

    it "handles already-deleted NLB, listener, and target group gracefully" do
      ec2_client.stub_responses(:delete_vpc_endpoint_service_configurations,
        Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound.new(nil, nil))
      ec2_client.stub_responses(:describe_vpc_endpoint_service_configurations,
        Aws::EC2::Errors::InvalidVpcEndpointServiceIdNotFound.new(nil, nil))
      elb_client.stub_responses(:delete_listener,
        Aws::ElasticLoadBalancingV2::Errors::ListenerNotFound.new(nil, nil))
      elb_client.stub_responses(:delete_target_group,
        Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound.new(nil, nil))
      elb_client.stub_responses(:delete_load_balancer,
        Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound.new(nil, nil))
      expect { nx.destroy }.to hop("wait_nlb_deletion")
    end

    it "skips AWS calls when no ARNs are set" do
      pl.update(nlb_arn: nil, service_id: nil)
      pl.ports.first.update(target_group_arn: nil, listener_arn: nil)
      expect(ec2_client).not_to receive(:delete_vpc_endpoint_service_configurations)
      expect(elb_client).not_to receive(:delete_load_balancer)
      expect { nx.destroy }.to hop("wait_nlb_deletion")
    end
  end

  describe "#wait_nlb_deletion" do
    before { pl.update(nlb_arn: "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/net/pl-test/abc") }

    it "naps if NLB still exists" do
      elb_client.stub_responses(:describe_load_balancers, load_balancers: [{state: {code: "active"}}])
      expect { nx.wait_nlb_deletion }.to nap(10)
    end

    it "destroys the record and pops when NLB is gone" do
      elb_client.stub_responses(:describe_load_balancers,
        Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound.new(nil, nil))
      expect { nx.wait_nlb_deletion }.to exit({"msg" => "PrivateLink deleted"})
      expect(PrivatelinkAwsResource[pl.id]).to be_nil
    end

    it "destroys the record and pops when no NLB ARN is set" do
      pl.update(nlb_arn: nil)
      expect { nx.wait_nlb_deletion }.to exit({"msg" => "PrivateLink deleted"})
      expect(PrivatelinkAwsResource[pl.id]).to be_nil
    end
  end
end
