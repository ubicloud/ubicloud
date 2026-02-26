# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::SubnetNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create(prog: "Vnet::Gcp::SubnetNexus", label: "start") }
  let(:project) { Project.create(name: "test-gcp-subnet") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }
  let(:credential) {
    LocationCredential.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }
  let(:ps) {
    credential
    PrivateSubnet.create(name: "ps", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting", project_id: project.id)
  }
  let(:vpc_name) { "ubicloud-gcp-us-central1" }
  let(:networks_client) { instance_double(Google::Cloud::Compute::V1::Networks::Rest::Client) }
  let(:subnetworks_client) { instance_double(Google::Cloud::Compute::V1::Subnetworks::Rest::Client) }
  let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }
  let(:global_ops_client) { instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client) }
  let(:region_ops_client) { instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client) }

  before do
    nx.instance_variable_set(:@private_subnet, ps)
    allow(credential).to receive_messages(
      networks_client:, subnetworks_client:,
      network_firewall_policies_client: nfp_client,
      global_operations_client: global_ops_client,
      region_operations_client: region_ops_client
    )
    nx.instance_variable_set(:@credential, credential)
  end

  describe ".vpc_name" do
    it "returns ubicloud-<location_name> for a location" do
      expect(described_class.vpc_name(location)).to eq(vpc_name)
    end
  end

  describe "#start" do
    it "hops to create_vpc" do
      expect { nx.start }.to hop("create_vpc")
    end
  end

  describe "#create_vpc" do
    it "skips creation if VPC already exists" do
      expect(networks_client).to receive(:get).with(
        project: "test-gcp-project",
        network: vpc_name
      ).and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name))

      expect { nx.create_vpc }.to hop("create_firewall_policy")
    end

    it "creates VPC and hops to wait_create_vpc" do
      expect(networks_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-vpc-123")
      expect(networks_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        nr = args[:network_resource]
        expect(nr.name).to eq(vpc_name)
        expect(nr.auto_create_subnetworks).to be(false)
        op
      end

      expect { nx.create_vpc }.to hop("wait_create_vpc")
      expect(st.stack.first["gcp_op_name"]).to eq("op-vpc-123")
    end

    it "handles AlreadyExistsError on INSERT from concurrent strands" do
      expect(networks_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))

      expect { nx.create_vpc }.to hop("create_firewall_policy")
    end
  end

  describe "#wait_create_vpc" do
    before do
      st.stack.first["gcp_op_name"] = "op-vpc-123"
      st.stack.first["gcp_op_scope"] = "global"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_create_vpc }.to nap(5)
    end

    it "hops to create_firewall_policy when operation completes" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_create_vpc }.to hop("create_firewall_policy")
    end

    it "raises if VPC creation fails" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(networks_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.wait_create_vpc }.to raise_error(RuntimeError, /VPC.*creation failed/)
    end

    it "continues if LRO errors but VPC was created" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "transient error")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(networks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name))

      expect { nx.wait_create_vpc }.to hop("create_firewall_policy")
    end
  end

  describe "#create_firewall_policy" do
    it "creates firewall policy if not exists and hops to create_vpc_deny_rules" do
      expect(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-policy")
      expect(nfp_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:firewall_policy_resource].name).to eq(vpc_name)
        op
      end

      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).with(
        project: "test-gcp-project", operation: "op-policy"
      ).and_return(done_op)

      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc")
      expect(nfp_client).to receive(:add_association) do |args|
        expect(args[:firewall_policy]).to eq(vpc_name)
        assoc = args[:firewall_policy_association_resource]
        expect(assoc.attachment_target).to include(vpc_name)
        assoc_op
      end

      expect(global_ops_client).to receive(:get).with(
        project: "test-gcp-project", operation: "op-assoc"
      ).and_return(done_op)

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "skips creation but ensures association when firewall policy already exists" do
      vpc_target = "projects/test-gcp-project/global/networks/#{vpc_name}"
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name, attachment_target: vpc_target
            )
          ])
      )
      expect(nfp_client).not_to receive(:insert)
      expect(nfp_client).not_to receive(:add_association)

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "creates association when firewall policy exists but has no association" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).not_to receive(:insert)

      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)
      expect(global_ops_client).to receive(:get).with(
        project: "test-gcp-project", operation: "op-assoc"
      ).and_return(done_op)

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "handles AlreadyExistsError on association from concurrent strands" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::AlreadyExistsError.new("association exists"))

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "handles InvalidArgumentError with 'already exists' on association" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("An association with that name already exists."))

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "re-raises InvalidArgumentError when not about association already existing" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("Invalid CIDR range"))

      expect { nx.create_firewall_policy }.to raise_error(Google::Cloud::InvalidArgumentError, /Invalid CIDR/)
    end
  end

  describe "#create_vpc_deny_rules" do
    it "creates 4 deny rules when they don't exist" do
      expect(nfp_client).to receive(:get_rule).exactly(4).times
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      created_rules = []
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).exactly(4).times.and_return(done_op)

      expect(nfp_client).to receive(:add_rule).exactly(4).times do |args|
        rule = args[:firewall_policy_rule_resource]
        created_rules << {
          priority: rule.priority,
          direction: rule.direction,
          action: rule.action
        }
        op
      end

      expect { nx.create_vpc_deny_rules }.to hop("create_subnet")

      expect(created_rules.map { |r| r[:action] }).to all(eq("deny"))
      directions = created_rules.map { |r| r[:direction] }
      expect(directions.count("INGRESS")).to eq(2)
      expect(directions.count("EGRESS")).to eq(2)
    end

    it "creates deny rules when get_rule raises InvalidArgumentError" do
      expect(nfp_client).to receive(:get_rule).exactly(4).times
        .and_raise(Google::Cloud::InvalidArgumentError.new("does not contain a rule"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).exactly(4).times.and_return(done_op)
      expect(nfp_client).to receive(:add_rule).exactly(4).times.and_return(op)

      expect { nx.create_vpc_deny_rules }.to hop("create_subnet")
    end

    it "skips creation when deny rules already exist" do
      rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new
      expect(nfp_client).to receive(:get_rule).exactly(4).times.and_return(rule)
      expect(nfp_client).not_to receive(:add_rule)

      expect { nx.create_vpc_deny_rules }.to hop("create_subnet")
    end
  end

  describe "#create_subnet" do
    it "skips creation if subnet already exists" do
      expect(subnetworks_client).to receive(:get).with(
        project: "test-gcp-project",
        region: "us-central1",
        subnetwork: "ubicloud-#{ps.ubid}"
      ).and_return(Google::Cloud::Compute::V1::Subnetwork.new)

      expect { nx.create_subnet }.to hop("create_subnet_allow_rules")
    end

    it "creates dual-stack subnet and hops to wait_create_subnet" do
      expect(subnetworks_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-subnet-123")
      expect(subnetworks_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:region]).to eq("us-central1")
        sr = args[:subnetwork_resource]
        expect(sr.name).to eq("ubicloud-#{ps.ubid}")
        expect(sr.ip_cidr_range).to eq("10.0.0.0/26")
        expect(sr.network).to eq("projects/test-gcp-project/global/networks/#{vpc_name}")
        expect(sr.private_ip_google_access).to be(true)
        expect(sr.stack_type).to eq("IPV4_IPV6")
        expect(sr.ipv6_access_type).to eq("EXTERNAL")
        op
      end

      expect { nx.create_subnet }.to hop("wait_create_subnet")
      expect(st.stack.first["gcp_op_name"]).to eq("op-subnet-123")
    end
  end

  describe "#wait_create_subnet" do
    before do
      st.stack.first["gcp_op_name"] = "op-subnet-123"
      st.stack.first["gcp_op_scope"] = "region"
      st.stack.first["gcp_op_scope_value"] = "us-central1"
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(region_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_create_subnet }.to nap(5)
    end

    it "hops to create_subnet_allow_rules when operation completes" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(region_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_create_subnet }.to hop("create_subnet_allow_rules")
    end

    it "raises if subnet creation fails" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(region_ops_client).to receive(:get).and_return(op)
      expect(subnetworks_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.wait_create_subnet }.to raise_error(RuntimeError, /subnet.*creation failed/)
    end

    it "continues if LRO errors but subnet was created" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "transient error")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(region_ops_client).to receive(:get).and_return(op)
      expect(subnetworks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Subnetwork.new(name: "ubicloud-#{ps.ubid}"))

      expect { nx.wait_create_subnet }.to hop("create_subnet_allow_rules")
    end
  end

  describe "#create_subnet_allow_rules" do
    it "creates IPv4+IPv6 egress allow rules with IP-based matching" do
      # Two policy rules (IPv4 egress + IPv6 egress), both new
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).twice.and_return(done_op)

      created_rules = []
      expect(nfp_client).to receive(:add_rule).twice do |args|
        rule = args[:firewall_policy_rule_resource]
        created_rules << {
          direction: rule.direction,
          action: rule.action,
          src_ip_ranges: rule.match.src_ip_ranges.to_a,
          dest_ip_ranges: rule.match.dest_ip_ranges.to_a
        }
        op
      end

      expect { nx.create_subnet_allow_rules }.to hop("wait")

      expect(created_rules).to all(include(direction: "EGRESS", action: "allow"))
      created_rules.each do |r|
        expect(r[:src_ip_ranges]).not_to be_empty
        expect(r[:dest_ip_ranges]).not_to be_empty
      end
    end

    it "skips creation when rules already exist" do
      rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new
      expect(nfp_client).to receive(:get_rule).twice.and_return(rule)
      expect(nfp_client).not_to receive(:add_rule)

      expect { nx.create_subnet_allow_rules }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(10 * 60)
    end

    it "clears refresh_keys semaphore when set" do
      st_real = Strand.create_with_id(ps, prog: "Vnet::Gcp::SubnetNexus", label: "wait")
      real_nx = described_class.new(st_real)
      real_nx.incr_refresh_keys
      expect { real_nx.wait }.to nap(10 * 60)
      expect(Semaphore.where(strand_id: st_real.id, name: "refresh_keys").count).to eq(0)
    end

    it "propagates firewall updates to VMs" do
      st_real = Strand.create_with_id(ps, prog: "Vnet::Gcp::SubnetNexus", label: "wait")
      real_nx = described_class.new(st_real)
      real_nx.incr_update_firewall_rules
      vm = instance_double(Vm)
      expect(real_nx).to receive(:private_subnet).and_return(ps).at_least(:once)
      expect(ps).to receive(:vms).and_return([vm])
      expect(vm).to receive(:incr_update_firewall_rules)
      expect { real_nx.wait }.to nap(10 * 60)
    end
  end

  describe "#destroy" do
    it "destroys the subnet and GCP resources when no nics or load balancers remain" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # delete_subnet_policy_rules
      expect(nfp_client).to receive(:remove_rule).twice

      # delete_gcp_subnet
      expect(subnetworks_client).to receive(:delete).with(
        project: "test-gcp-project",
        region: "us-central1",
        subnetwork: "ubicloud-#{ps.ubid}"
      )

      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles already-deleted GCP subnet" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # delete_subnet_policy_rules — already deleted
      expect(nfp_client).to receive(:remove_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "naps when GCE subnet is still in use by a terminating instance" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:remove_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(
        Google::Cloud::InvalidArgumentError.new("The subnetwork resource is already being used by 'projects/test/instances/vm-1'")
      )
      expect { nx.destroy }.to nap(5)
    end

    it "re-raises InvalidArgumentError when not about subnet being used" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:remove_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(
        Google::Cloud::InvalidArgumentError.new("Invalid CIDR range")
      )
      expect { nx.destroy }.to raise_error(Google::Cloud::InvalidArgumentError)
    end

    it "destroys nics and load balancers first" do
      nic = instance_double(Nic)
      lb = instance_double(LoadBalancer)
      expect(ps).to receive(:nics).and_return([nic]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([lb]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)
      expect(nic).to receive(:incr_destroy)
      expect(lb).to receive(:incr_destroy)
      expect(nx).to receive(:rand).with(5..10).and_return(7)
      expect { nx.destroy }.to nap(7)
    end

    it "handles policy not found during rule cleanup" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # Both priority rules not found (inner rescue catches each one)
      expect(nfp_client).to receive(:remove_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete)
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles InvalidArgumentError during rule cleanup" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:remove_rule).twice
        .and_raise(Google::Cloud::InvalidArgumentError.new("does not contain a rule"))

      expect(subnetworks_client).to receive(:delete)
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end
  end

  describe "#wait_for_compute_global_op" do
    it "polls until done" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-test")
      done = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).and_return(done)

      nx.send(:wait_for_compute_global_op, op)
    end

    it "polls multiple times if not done" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-test")
      running = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      done = Google::Cloud::Compute::V1::Operation.new(status: :DONE)

      expect(global_ops_client).to receive(:get).and_return(running, done)
      allow(nx).to receive(:sleep)

      nx.send(:wait_for_compute_global_op, op)
    end

    it "handles non-operation objects" do
      op = double("plain_op") # rubocop:disable RSpec/VerifiedDoubles
      expect { nx.send(:wait_for_compute_global_op, op) }.not_to raise_error
    end
  end
end
