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
      net4: "10.0.0.0/26", state: "waiting", project_id: project.id, firewall_priority: 1000)
  }
  let(:vpc_name) { "ubicloud-#{project.ubid}" }
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
    it "returns ubicloud-<project_ubid> for a project" do
      expect(described_class.vpc_name(project)).to eq(vpc_name)
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

    it "clears op and hops to create_vpc when LRO fails and VPC does not exist" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(networks_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.wait_create_vpc }.to hop("create_vpc")
      expect(st.stack.first["gcp_op_name"]).to be_nil
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

      # Re-fetch after creation to check associations
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )

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

    it "proceeds when association raises AlreadyExistsError from concurrent strand" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::AlreadyExistsError.new("association exists"))

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "proceeds when association raises InvalidArgumentError with 'already exists'" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("An association with that name already exists."))

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "re-fetches and adds association after AlreadyExistsError from policy insert" do
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("policy already exists"))

      # Re-fetch returns policy without association → adds association
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc-recovery")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)
      expect(global_ops_client).to receive(:get).with(
        project: "test-gcp-project", operation: "op-assoc-recovery"
      ).and_return(done_op)

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "skips association after AlreadyExistsError from policy insert when already associated" do
      vpc_target = "projects/test-gcp-project/global/networks/#{vpc_name}"
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("policy already exists"))

      # Re-fetch returns policy with association already present
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name, attachment_target: vpc_target
            )
          ])
      )
      expect(nfp_client).not_to receive(:add_association)

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "naps when VPC resource is not ready for association" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("The resource 'projects/test/global/networks/ubicloud-gcp-us-central1' is not ready"))

      expect { nx.create_firewall_policy }.to nap(5)
    end

    it "re-raises InvalidArgumentError when not about association already existing or resource not ready" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("Invalid CIDR range"))

      expect { nx.create_firewall_policy }.to raise_error(Google::Cloud::InvalidArgumentError, /Invalid CIDR/)
    end

    # rubocop:disable RSpec/VerifiedDoubles
    it "adds association when re-fetch after insert AlreadyExistsError returns nil associations" do
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:insert).and_raise(Google::Cloud::AlreadyExistsError.new("exists"))

      # Re-fetch returns policy with nil associations
      policy_nil_assoc = double("policy", associations: nil)
      expect(nfp_client).to receive(:get).and_return(policy_nil_assoc)

      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc-nil")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)
      expect(global_ops_client).to receive(:get).with(
        project: "test-gcp-project", operation: "op-assoc-nil"
      ).and_return(done_op)

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end
    # rubocop:enable RSpec/VerifiedDoubles
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

    it "skips creation when deny rules already exist and match" do
      # Return rules that match the desired state (direction, action, src/dest ranges, layer4_configs)
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      expect(nfp_client).to receive(:get_rule).exactly(4).times do |args|
        prio = args[:priority]
        case prio
        when 65534
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "INGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              src_ip_ranges: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
              layer4_configs: [all_proto]
            )
          )
        when 65533
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "EGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              dest_ip_ranges: ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
              layer4_configs: [all_proto]
            )
          )
        when 65532
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "INGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              src_ip_ranges: ["fd20::/20"],
              layer4_configs: [all_proto]
            )
          )
        when 65531
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "EGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              dest_ip_ranges: ["fd20::/20"],
              layer4_configs: [all_proto]
            )
          )
        end
      end
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

      expect { nx.create_subnet }.to hop("create_tag_resources")
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

    it "hops to create_tag_resources when operation completes" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(region_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_create_subnet }.to hop("create_tag_resources")
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

      expect { nx.wait_create_subnet }.to hop("create_tag_resources")
    end
  end

  describe "#create_tag_resources" do
    let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }

    before do
      allow(credential).to receive(:crm_client).and_return(crm_client)
      allow(networks_client).to receive(:get)
        .with(project: "test-gcp-project", network: vpc_name)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 12345))
    end

    it "creates tag key and tag value, stores in frame, and hops to create_subnet_allow_rules" do
      tag_key_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, response: {"name" => "tagKeys/111"}
      )
      expect(crm_client).to receive(:create_tag_key).and_return(tag_key_op)

      tag_value_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, response: {"name" => "tagValues/222"}
      )
      expect(crm_client).to receive(:create_tag_value).and_return(tag_value_op)

      expect { nx.create_tag_resources }.to hop("create_subnet_allow_rules")
      expect(st.stack.first["tag_key_name"]).to eq("tagKeys/111")
      expect(st.stack.first["subnet_tag_value_name"]).to eq("tagValues/222")
    end

    it "handles existing tag key (409 conflict) and creates tag value" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

      existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/existing", short_name: "ubicloud-subnet-#{ps.ubid}"
      )
      resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key])
      expect(crm_client).to receive(:list_tag_keys).and_return(resp)

      tag_value_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, response: {"name" => "tagValues/333"}
      )
      expect(crm_client).to receive(:create_tag_value).and_return(tag_value_op)

      expect { nx.create_tag_resources }.to hop("create_subnet_allow_rules")
      expect(st.stack.first["tag_key_name"]).to eq("tagKeys/existing")
      expect(st.stack.first["subnet_tag_value_name"]).to eq("tagValues/333")
    end
  end

  describe "#create_subnet_allow_rules" do
    let(:subnet_tag_value_name) { "tagValues/222" }

    before do
      st.stack.first["subnet_tag_value_name"] = subnet_tag_value_name
      st.modified!(:stack)
      st.save_changes
      nx.instance_variable_set(:@frame, nil)
    end

    it "creates IPv4+IPv6 tag-based egress allow rules" do
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
          dest_ip_ranges: rule.match.dest_ip_ranges.to_a,
          target_secure_tags: rule.target_secure_tags.map(&:name)
        }
        op
      end

      expect { nx.create_subnet_allow_rules }.to hop("wait")

      expect(created_rules).to all(include(direction: "EGRESS", action: "allow"))
      created_rules.each do |r|
        expect(r[:dest_ip_ranges]).not_to be_empty
        expect(r[:target_secure_tags]).to eq([subnet_tag_value_name])
      end
    end

    it "skips creation when rules already exist and match" do
      net4 = ps.net4.to_s
      net6 = ps.net6.to_s
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      tag = Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: subnet_tag_value_name)
      expect(nfp_client).to receive(:get_rule).twice do |args|
        prio = args[:priority]
        if prio.even?
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "EGRESS", action: "allow",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              dest_ip_ranges: [net4],
              layer4_configs: [all_proto]
            ),
            target_secure_tags: [tag]
          )
        else
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "EGRESS", action: "allow",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              dest_ip_ranges: [net6],
              layer4_configs: [all_proto]
            ),
            target_secure_tags: [tag]
          )
        end
      end
      expect(nfp_client).not_to receive(:add_rule)

      expect { nx.create_subnet_allow_rules }.to hop("wait")
    end

    it "detects mismatch when rule has correct IPs but wrong protocol" do
      net4 = ps.net4.to_s
      net6 = ps.net6.to_s
      tcp_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp")
      tag = Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: subnet_tag_value_name)
      wrong_proto_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [net4],
          layer4_configs: [tcp_proto]
        ),
        target_secure_tags: [tag]
      )
      wrong_proto_rule6 = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [net6],
          layer4_configs: [tcp_proto]
        ),
        target_secure_tags: [tag]
      )
      expect(nfp_client).to receive(:get_rule).twice do |args|
        args[:priority].even? ? wrong_proto_rule : wrong_proto_rule6
      end

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).twice.and_return(done_op)
      expect(nfp_client).to receive(:patch_rule).twice.and_return(op)
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, overwriting rule", anything).twice

      expect { nx.create_subnet_allow_rules }.to hop("wait")
    end

    it "overwrites foreign rule on priority collision and logs warning" do
      foreign_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.99.0.0/24"]
        )
      )
      expect(nfp_client).to receive(:get_rule).twice.and_return(foreign_rule)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).twice.and_return(done_op)
      expect(nfp_client).to receive(:patch_rule).twice.and_return(op)

      expect(Clog).to receive(:emit).with("GCP firewall priority collision, overwriting rule", anything).twice

      expect { nx.create_subnet_allow_rules }.to hop("wait")
    end

    it "allocates firewall_priority when not yet set" do
      ps.update(firewall_priority: nil)

      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      done_op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).twice.and_return(done_op)
      expect(nfp_client).to receive(:add_rule).twice.and_return(op)

      expect { nx.create_subnet_allow_rules }.to hop("wait")
      expect(ps.reload.firewall_priority).to eq(1000)
    end
  end

  describe "#allocate_subnet_firewall_priority" do
    before do
      ps.update(firewall_priority: nil)
    end

    it "allocates the lowest available even slot starting at 1000" do
      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1000)
    end

    it "gap-fills: uses lowest available slot when 1000 is taken" do
      other_ps = PrivateSubnet.create(name: "ps2", location_id: location.id, net6: "fd11::/64",
        net4: "10.0.1.0/26", state: "waiting", project_id: project.id, firewall_priority: 1000)

      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1002)

      other_ps.destroy
    end

    it "gap-fills when middle slot is free" do
      ps1 = PrivateSubnet.create(name: "ps1", location_id: location.id, net6: "fd11::/64",
        net4: "10.0.1.0/26", state: "waiting", project_id: project.id, firewall_priority: 1000)
      ps3 = PrivateSubnet.create(name: "ps3", location_id: location.id, net6: "fd12::/64",
        net4: "10.0.2.0/26", state: "waiting", project_id: project.id, firewall_priority: 1004)

      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1002)

      ps1.destroy
      ps3.destroy
    end

    it "raises when all slots are exhausted" do
      fake_ds = instance_double(Sequel::Dataset)
      allow(fake_ds).to receive_messages(where: fake_ds, exclude: fake_ds, select_map: (1000..8998).step(2).to_a)
      allow(DB).to receive(:[]).and_call_original
      allow(DB).to receive(:[]).with(:private_subnet).and_return(fake_ds)

      expect { nx.send(:allocate_subnet_firewall_priority) }
        .to raise_error(RuntimeError, /GCP firewall priority range exhausted for project/)
    end

    it "retries on unique constraint violation" do
      attempt = 0
      allow(ps).to receive(:update).and_wrap_original do |m, hash|
        attempt += 1
        raise Sequel::UniqueConstraintViolation, "dup" if attempt == 1 && hash[:firewall_priority]
        m.call(hash)
      end

      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1000)
    end

    it "raises after exceeding retry limit on persistent unique constraint violations" do
      allow(ps).to receive(:update).and_wrap_original do |m, hash|
        raise Sequel::UniqueConstraintViolation, "dup" if hash.key?(:firewall_priority) && !hash[:firewall_priority].nil?
        m.call(hash)
      end

      expect { nx.send(:allocate_subnet_firewall_priority) }
        .to raise_error(RuntimeError, /allocation failed after .* concurrent retries/)
    end

    it "silently ignores errors during nil-reset on retry" do
      attempt = 0
      allow(ps).to receive(:update).and_wrap_original do |m, hash|
        attempt += 1
        raise Sequel::UniqueConstraintViolation, "dup" if attempt == 1 && hash[:firewall_priority]
        raise Sequel::Error, "reset failed" if attempt == 2 && hash[:firewall_priority].nil?
        m.call(hash)
      end

      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1000)
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
    let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }

    before do
      allow(credential).to receive(:crm_client).and_return(crm_client)
      # Default: no tag key found (skip tag cleanup)
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
      )
      # Default: stub VPC-level cleanup (tested separately)
      allow(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))
      allow(nfp_client).to receive(:delete)
      allow(networks_client).to receive(:get)
        .with(project: "test-gcp-project", network: vpc_name)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 55555))
      allow(networks_client).to receive(:delete)
    end

    it "destroys the subnet and GCP resources when no nics or load balancers remain" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # delete_subnet_policy_rules — get_rule returns matching rule, then remove
      matching_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [ps.net4.to_s]
        )
      )
      expect(nfp_client).to receive(:get_rule).twice.and_return(matching_rule)
      remove_op = instance_double(Gapic::GenericLRO::Operation, name: "op-remove-rule")
      expect(nfp_client).to receive(:remove_rule).twice.and_return(remove_op)
      allow(global_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))

      # delete_gcp_subnet
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).with(
        project: "test-gcp-project",
        region: "us-central1",
        subnetwork: "ubicloud-#{ps.ubid}"
      ).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))

      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "cleans up tag value and tag key (per-subnet)" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # delete_subnet_policy_rules
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      # delete_subnet_tag_resources — per-subnet tag key
      tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
      )
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
      )

      subnet_tv = Google::Apis::CloudresourcemanagerV3::TagValue.new(
        name: "tagValues/222", short_name: "member"
      )
      expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111")
        .and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [subnet_tv])
        )

      delete_tv_op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
      expect(crm_client).to receive(:delete_tag_value).with("tagValues/222").and_return(delete_tv_op)
      delete_tk_op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
      expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111").and_return(delete_tk_op)

      # delete_gcp_subnet
      expect(subnetworks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles 404 during tag cleanup" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      # Tag key exists but list_tag_values raises 404
      tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
      )
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
      )
      expect(crm_client).to receive(:list_tag_values)
        .and_raise(Google::Apis::ClientError.new("not found", status_code: 404))

      expect(subnetworks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "skips deleting rules that belong to a foreign subnet (collision)" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # get_rule returns a rule belonging to a different subnet
      foreign_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.99.0.0/24"]
        )
      )
      expect(nfp_client).to receive(:get_rule).twice.and_return(foreign_rule)
      expect(nfp_client).not_to receive(:remove_rule)

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles already-deleted GCP subnet" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # delete_subnet_policy_rules — rules already deleted
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "naps when GCE subnet is still in use by a terminating instance" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:get_rule).twice
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

      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(
        Google::Cloud::InvalidArgumentError.new("Invalid CIDR range")
      )
      expect { nx.destroy }.to raise_error(Google::Cloud::InvalidArgumentError)
    end

    it "skips rule deletion when firewall_priority is nil (early destroy)" do
      ps.update(firewall_priority: nil)
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).not_to receive(:get_rule)
      expect(nfp_client).not_to receive(:remove_rule)

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
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

      # get_rule not found for both priorities
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles InvalidArgumentError during rule cleanup" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::InvalidArgumentError.new("does not contain a rule"))

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "cleans up VPC-level resources when last GCP subnet is destroyed" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # Stub subnet-level cleanup
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)

      # delete_all_firewall_tag_keys — scoped to this VPC's network
      allow(networks_client).to receive(:get)
        .with(project: "test-gcp-project", network: vpc_name)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 55555))
      vpc_network_link = "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555"

      fw_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/999", short_name: "ubicloud-fw-fwtest123", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => vpc_network_link}
      )
      # Tag key from another VPC — should be skipped
      other_vpc_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/777", short_name: "ubicloud-fw-fwother", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/99999"}
      )
      # Tag key with nil purpose_data — should also be skipped
      nil_pd_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/666", short_name: "ubicloud-fw-fwnilpd", purpose: "GCE_FIREWALL"
      )
      tag_val = Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/888", short_name: "active")
      allow(crm_client).to receive_messages(list_tag_keys: Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [fw_tag_key, other_vpc_tag_key, nil_pd_tag_key]), list_tag_values: Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [tag_val]))
      done_op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
      expect(crm_client).to receive(:delete_tag_value).with("tagValues/888").and_return(done_op)
      expect(crm_client).to receive(:delete_tag_key).with("tagKeys/999").and_return(done_op)

      # delete_firewall_policy — policy exists with association
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        associations: [Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: vpc_name)]
      )
      expect(nfp_client).to receive(:get).with(
        project: "test-gcp-project", firewall_policy: vpc_name
      ).and_return(policy)
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-remove-assoc")
      expect(nfp_client).to receive(:remove_association).and_return(op)
      allow(global_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      delete_policy_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-policy")
      expect(nfp_client).to receive(:delete).with(
        project: "test-gcp-project", firewall_policy: vpc_name
      ).and_return(delete_policy_op)

      # delete_vpc_network
      expect(networks_client).to receive(:delete).with(
        project: "test-gcp-project", network: vpc_name
      )

      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "skips VPC cleanup when other GCP subnets exist in the project" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # Stub subnet-level cleanup
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))

      # Create a second GCP subnet in the same project
      PrivateSubnet.create(name: "ps2", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbc::/64",
        net4: "10.0.1.0/26", state: "waiting", project_id: project.id)

      expect(ps).to receive(:destroy)
      # Should NOT call VPC cleanup methods
      expect(nx).not_to receive(:delete_all_firewall_tag_keys)
      expect(nx).not_to receive(:delete_firewall_policy)
      expect(nx).not_to receive(:delete_vpc_network)

      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles errors during VPC cleanup gracefully" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      # Stub subnet-level cleanup
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)

      # gcp_network_self_link_with_id for delete_all_firewall_tag_keys
      allow(networks_client).to receive(:get)
        .with(project: "test-gcp-project", network: vpc_name)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 55555))

      # list_tag_keys: first call (subnet tag cleanup) returns empty, second call (VPC cleanup) raises
      call_count = 0
      allow(crm_client).to receive(:list_tag_keys) do
        call_count += 1
        if call_count == 1
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
        else
          raise Google::Apis::ClientError.new("permission denied", status_code: 403)
        end
      end

      # delete_firewall_policy — not found
      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      # delete_vpc_network — not ready
      expect(networks_client).to receive(:delete)
        .and_raise(Google::Cloud::InvalidArgumentError.new("not ready"))

      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles per-tag-key errors independently during VPC cleanup" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)

      # delete_all_firewall_tag_keys — tag key found but delete_tag_key raises per-key error
      allow(networks_client).to receive(:get)
        .with(project: "test-gcp-project", network: vpc_name)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 55555))
      vpc_network_link = "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555"

      fw_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/999", short_name: "ubicloud-fw-fwfail", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => vpc_network_link}
      )
      allow(crm_client).to receive_messages(list_tag_keys: Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [fw_tag_key]), list_tag_values: Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: []))
      allow(crm_client).to receive(:delete_tag_key)
        .and_raise(Google::Cloud::PermissionDeniedError.new("denied"))

      # delete_firewall_policy — general Cloud error (not NotFoundError)
      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::InternalError.new("internal"))

      expect(networks_client).to receive(:delete)

      expect { nx.destroy }.to exit({"msg" => "subnet destroyed"})
    end

    it "handles RuntimeError from CRM LRO during VPC firewall tag cleanup" do
      expect(ps).to receive(:nics).and_return([]).at_least(:once)
      expect(ps).to receive(:load_balancers).and_return([]).at_least(:once)
      expect(ps).to receive(:remove_all_firewalls)

      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      allow(region_ops_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Operation.new(status: :DONE))
      expect(ps).to receive(:destroy)

      # delete_all_firewall_tag_keys — RuntimeError from CRM LRO ghost bindings
      allow(networks_client).to receive(:get)
        .with(project: "test-gcp-project", network: vpc_name)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 55555))
      vpc_network_link = "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555"

      fw_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/999", short_name: "ubicloud-fw-fwghost", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => vpc_network_link}
      )
      tag_val = Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/888", short_name: "active")
      allow(crm_client).to receive_messages(
        list_tag_keys: Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [fw_tag_key]),
        list_tag_values: Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [tag_val])
      )
      allow(crm_client).to receive(:delete_tag_value)
        .and_raise(RuntimeError.new("CRM operation op-1 failed: Cannot delete tag value still attached to resources"))

      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:delete)

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

    it "raises when operation completes with an error" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-test")
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "RESOURCE_ALREADY_EXISTS", message: "already exists")
      failed_op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(global_ops_client).to receive(:get).and_return(failed_op)

      expect { nx.send(:wait_for_compute_global_op, op) }
        .to raise_error(RuntimeError, /op-test.*failed/)
    end

    it "raises when operation does not complete within polling timeout" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-test")
      running = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)

      expect(global_ops_client).to receive(:get).exactly(30).times.and_return(running)
      allow(nx).to receive(:sleep)

      expect { nx.send(:wait_for_compute_global_op, op) }
        .to raise_error(RuntimeError, /op-test.*did not complete within timeout/)
    end

    it "handles non-operation objects" do
      op = double("plain_op") # rubocop:disable RSpec/VerifiedDoubles
      expect { nx.send(:wait_for_compute_global_op, op) }.not_to raise_error
    end
  end

  describe "#policy_rule_matches_desired?" do
    it "returns false and covers nil-match &. branches when existing.match is nil" do
      rule_no_match = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "deny"
        # match is nil — triggers &.src_ip_ranges, &.dest_ip_ranges, &.layer4_configs nil paths
      )
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      result = nx.send(:policy_rule_matches_desired?, rule_no_match,
        direction: "EGRESS", action: "deny",
        src_ip_ranges: nil, dest_ip_ranges: nil,
        layer4_configs: [all_proto])
      expect(result).to be(false)
    end

    it "matches when target_secure_tags are equal" do
      tag = Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: "tagValues/123")
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.0.0.0/26"],
          layer4_configs: [all_proto]
        ),
        target_secure_tags: [tag]
      )
      result = nx.send(:policy_rule_matches_desired?, rule,
        direction: "EGRESS", action: "allow",
        src_ip_ranges: nil, dest_ip_ranges: ["10.0.0.0/26"],
        layer4_configs: [all_proto],
        target_secure_tags: ["tagValues/123"])
      expect(result).to be(true)
    end

    it "returns false when target_secure_tags differ" do
      tag = Google::Cloud::Compute::V1::FirewallPolicyRuleSecureTag.new(name: "tagValues/999")
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.0.0.0/26"],
          layer4_configs: [all_proto]
        ),
        target_secure_tags: [tag]
      )
      result = nx.send(:policy_rule_matches_desired?, rule,
        direction: "EGRESS", action: "allow",
        src_ip_ranges: nil, dest_ip_ranges: ["10.0.0.0/26"],
        layer4_configs: [all_proto],
        target_secure_tags: ["tagValues/123"])
      expect(result).to be(false)
    end

    it "handles nil target_secure_tags on both sides" do
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "deny",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.0.0.0/8"],
          layer4_configs: [all_proto]
        )
      )
      result = nx.send(:policy_rule_matches_desired?, rule,
        direction: "EGRESS", action: "deny",
        src_ip_ranges: nil, dest_ip_ranges: ["10.0.0.0/8"],
        layer4_configs: [all_proto])
      expect(result).to be(true)
    end
  end

  describe "#normalize_layer4_configs" do
    # rubocop:disable RSpec/VerifiedDoubles
    it "handles layer4 configs with nil ports (covers &.to_a nil branch)" do
      config = double("layer4_config", ip_protocol: "tcp", ports: nil)
      result = nx.send(:normalize_layer4_configs, [config])
      expect(result).to eq([["tcp", []]])
    end
    # rubocop:enable RSpec/VerifiedDoubles
  end

  describe "#delete_subnet_policy_rules" do
    it "skips rule when existing rule has nil match (covers &.dest_ip_ranges nil branch)" do
      rule_no_match = Google::Cloud::Compute::V1::FirewallPolicyRule.new
      # match is nil — match&.dest_ip_ranges&.any? returns nil → next is executed
      expect(nfp_client).to receive(:get_rule).twice.and_return(rule_no_match)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:delete_subnet_policy_rules)
    end
  end

  describe "#delete_gcp_subnet (LRO wait)" do
    it "waits for the delete LRO before returning" do
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      done = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(region_ops_client).to receive(:get).with(
        project: "test-gcp-project", region: "us-central1", operation: "op-delete-subnet"
      ).and_return(done)

      expect(nx.send(:delete_gcp_subnet)).to be(true)
    end

    it "raises when delete LRO fails" do
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-fail")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      failed_op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry])
      )
      expect(region_ops_client).to receive(:get).and_return(failed_op)

      expect { nx.send(:delete_gcp_subnet) }.to raise_error(RuntimeError, /op-delete-fail.*failed/)
    end

    it "raises when delete LRO times out" do
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-timeout")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)
      running = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(region_ops_client).to receive(:get).exactly(30).times.and_return(running)
      allow(nx).to receive(:sleep)

      expect { nx.send(:delete_gcp_subnet) }.to raise_error(RuntimeError, /op-delete-timeout.*did not complete within timeout/)
    end
  end

  describe "secure tag helpers" do
    let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }

    before do
      allow(credential).to receive(:crm_client).and_return(crm_client)
    end

    describe "#gcp_network_self_link_with_id" do
      it "returns selfLinkWithId URL using numeric network ID" do
        allow(networks_client).to receive(:get)
          .with(project: "test-gcp-project", network: vpc_name)
          .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 55555))

        result = nx.send(:gcp_network_self_link_with_id)
        expect(result).to eq("https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")
      end

      it "raises when network has no numeric ID" do
        allow(networks_client).to receive(:get)
          .with(project: "test-gcp-project", network: vpc_name)
          .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name))

        expect { nx.send(:gcp_network_self_link_with_id) }.to raise_error(RuntimeError, /has no numeric ID/)
      end
    end

    describe "#tag_key_short_name" do
      it "returns ubicloud-subnet-<private_subnet_ubid>" do
        expect(nx.send(:tag_key_short_name)).to eq("ubicloud-subnet-#{ps.ubid}")
      end
    end

    describe "#subnet_tag_short_name" do
      it "returns member" do
        expect(nx.send(:subnet_tag_short_name)).to eq("member")
      end
    end

    describe "#tag_key_parent" do
      it "returns projects/<gcp_project_id>" do
        expect(nx.send(:tag_key_parent)).to eq("projects/test-gcp-project")
      end
    end

    describe "#ensure_tag_key" do
      before do
        allow(networks_client).to receive(:get)
          .with(project: "test-gcp-project", network: vpc_name)
          .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 98765))
      end

      it "creates a tag key and returns its name from the completed operation" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, response: {"name" => "tagKeys/123456"}
        )
        expect(crm_client).to receive(:create_tag_key) do |tk|
          expect(tk.short_name).to eq("ubicloud-subnet-#{ps.ubid}")
          expect(tk.parent).to eq("projects/test-gcp-project")
          expect(tk.purpose).to eq("GCE_FIREWALL")
          expect(tk.purpose_data).to eq({"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/98765"})
          op
        end

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/123456")
      end

      it "polls the operation until done" do
        pending_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/tk-create", done: false
        )
        done_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, response: {"name" => "tagKeys/789"}
        )
        expect(crm_client).to receive(:create_tag_key).and_return(pending_op)
        expect(crm_client).to receive(:get_operation).with("operations/tk-create").and_return(done_op)
        allow(nx).to receive(:sleep)

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/789")
      end

      it "falls back to lookup on 409 conflict" do
        expect(crm_client).to receive(:create_tag_key)
          .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

        existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/existing-123",
          short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key])
        expect(crm_client).to receive(:list_tag_keys)
          .with(parent: "projects/test-gcp-project").and_return(resp)

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/existing-123")
      end

      it "raises on 409 if lookup finds nothing" do
        expect(crm_client).to receive(:create_tag_key)
          .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)

        expect { nx.send(:ensure_tag_key) }.to raise_error(RuntimeError, /conflict but not found/)
      end

      it "falls back to listing when operation response is nil" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/fallback-123",
          short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/fallback-123")
      end

      it "raises when operation response is nil and listing fails" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)

        expect { nx.send(:ensure_tag_key) }
          .to raise_error(RuntimeError, /created but name not found/)
      end

      it "re-raises non-409 client errors" do
        expect(crm_client).to receive(:create_tag_key)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:ensure_tag_key) }.to raise_error(Google::Apis::ClientError, /forbidden/)
      end

      it "handles ALREADY_EXISTS from CRM LRO by looking up existing key" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "ALREADY_EXISTS: tag key already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-1", error:)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/existing-lro-123",
          short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/existing-lro-123")
      end

      it "raises on ALREADY_EXISTS from LRO when lookup returns nothing" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "ALREADY_EXISTS: tag key already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-1", error:)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)

        expect { nx.send(:ensure_tag_key) }.to raise_error(RuntimeError, /conflict but not found/)
      end

      it "re-raises non-ALREADY_EXISTS LRO errors" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "PERMISSION_DENIED: access denied")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-1", error:)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        expect { nx.send(:ensure_tag_key) }.to raise_error(RuntimeError, /PERMISSION_DENIED/)
      end
    end

    describe "#lookup_tag_key" do
      it "finds the matching tag key by short_name" do
        matching = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        other = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/222", short_name: "other-key"
        )
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [other, matching])
        expect(crm_client).to receive(:list_tag_keys)
          .with(parent: "projects/test-gcp-project").and_return(resp)

        result = nx.send(:lookup_tag_key)
        expect(result.name).to eq("tagKeys/111")
      end

      it "returns nil when no matching tag key exists" do
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)

        expect(nx.send(:lookup_tag_key)).to be_nil
      end

      it "returns nil when tag_keys is nil" do
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)

        expect(nx.send(:lookup_tag_key)).to be_nil
      end
    end

    describe "#ensure_tag_value" do
      it "creates a tag value and returns its name" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, response: {"name" => "tagValues/456"}
        )
        expect(crm_client).to receive(:create_tag_value) do |tv|
          expect(tv.short_name).to eq("my-value")
          expect(tv.parent).to eq("tagKeys/123")
          op
        end

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "my-value")).to eq("tagValues/456")
      end

      it "falls back to lookup on 409 conflict" do
        expect(crm_client).to receive(:create_tag_value)
          .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

        existing = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/existing-456", short_name: "my-value"
        )
        resp = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [existing])
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/123").and_return(resp)

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "my-value")).to eq("tagValues/existing-456")
      end

      it "raises on 409 if lookup finds nothing" do
        expect(crm_client).to receive(:create_tag_value)
          .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

        resp = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [])
        expect(crm_client).to receive(:list_tag_values).and_return(resp)

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "my-value") }
          .to raise_error(RuntimeError, /conflict but not found/)
      end

      it "falls back to listing when operation response is nil" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_value).and_return(op)

        existing = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/fallback-456", short_name: "my-value"
        )
        resp = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [existing])
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/123").and_return(resp)

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "my-value")).to eq("tagValues/fallback-456")
      end

      it "raises when operation response is nil and listing fails" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_value).and_return(op)

        resp = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [])
        expect(crm_client).to receive(:list_tag_values).and_return(resp)

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "my-value") }
          .to raise_error(RuntimeError, /created but name not found/)
      end

      it "re-raises non-409 client errors" do
        expect(crm_client).to receive(:create_tag_value)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "v") }
          .to raise_error(Google::Apis::ClientError, /forbidden/)
      end

      it "handles ALREADY_EXISTS from CRM LRO by looking up existing value" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "ALREADY_EXISTS: tag value already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-1", error:)
        expect(crm_client).to receive(:create_tag_value).and_return(op)

        existing = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/existing-lro-456", short_name: "my-value"
        )
        resp = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [existing])
        expect(crm_client).to receive(:list_tag_values).and_return(resp)

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "my-value")).to eq("tagValues/existing-lro-456")
      end

      it "re-raises non-ALREADY_EXISTS LRO errors for tag value" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "PERMISSION_DENIED: access denied")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-1", error:)
        expect(crm_client).to receive(:create_tag_value).and_return(op)

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "my-value") }
          .to raise_error(RuntimeError, /PERMISSION_DENIED/)
      end
    end

    describe "#delete_tag_value" do
      it "deletes and waits for the operation" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
        expect(crm_client).to receive(:delete_tag_value).with("tagValues/456").and_return(op)

        nx.send(:delete_tag_value, "tagValues/456")
      end

      it "ignores 404 not found" do
        expect(crm_client).to receive(:delete_tag_value)
          .and_raise(Google::Apis::ClientError.new("not found", status_code: 404))

        expect { nx.send(:delete_tag_value, "tagValues/456") }.not_to raise_error
      end

      it "ignores NOT_FOUND from CRM LRO" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "NOT_FOUND: tag value not found")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-del", error:)
        expect(crm_client).to receive(:delete_tag_value).and_return(op)

        expect { nx.send(:delete_tag_value, "tagValues/456") }.not_to raise_error
      end

      it "re-raises non-NOT_FOUND LRO errors" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "PERMISSION_DENIED: access denied")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-del", error:)
        expect(crm_client).to receive(:delete_tag_value).and_return(op)

        expect { nx.send(:delete_tag_value, "tagValues/456") }
          .to raise_error(RuntimeError, /PERMISSION_DENIED/)
      end

      it "re-raises non-404 errors" do
        expect(crm_client).to receive(:delete_tag_value)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:delete_tag_value, "tagValues/456") }
          .to raise_error(Google::Apis::ClientError)
      end
    end

    describe "#delete_tag_key" do
      it "deletes and waits for the operation" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/123").and_return(op)

        nx.send(:delete_tag_key, "tagKeys/123")
      end

      it "ignores 404 not found" do
        expect(crm_client).to receive(:delete_tag_key)
          .and_raise(Google::Apis::ClientError.new("not found", status_code: 404))

        expect { nx.send(:delete_tag_key, "tagKeys/123") }.not_to raise_error
      end

      it "ignores NOT_FOUND from CRM LRO" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "NOT_FOUND: tag key not found")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-del", error:)
        expect(crm_client).to receive(:delete_tag_key).and_return(op)

        expect { nx.send(:delete_tag_key, "tagKeys/123") }.not_to raise_error
      end

      it "re-raises non-NOT_FOUND LRO errors" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(message: "PERMISSION_DENIED: access denied")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, name: "op-del", error:)
        expect(crm_client).to receive(:delete_tag_key).and_return(op)

        expect { nx.send(:delete_tag_key, "tagKeys/123") }
          .to raise_error(RuntimeError, /PERMISSION_DENIED/)
      end

      it "re-raises non-404 errors" do
        expect(crm_client).to receive(:delete_tag_key)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:delete_tag_key, "tagKeys/123") }
          .to raise_error(Google::Apis::ClientError)
      end
    end

    describe "#lookup_tag_value_name" do
      it "returns nil when tag_values is nil in the response" do
        resp = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/123").and_return(resp)

        expect(nx.send(:lookup_tag_value_name, "tagKeys/123", "member")).to be_nil
      end
    end

    describe "#delete_subnet_tag_resources" do
      it "returns early when no tag key exists" do
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)
        expect(crm_client).not_to receive(:list_tag_values)

        nx.send(:delete_subnet_tag_resources)
      end

      it "skips tag value deletion when member tag value not found but still deletes key" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
        )

        other_tv = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/333", short_name: "other"
        )
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111")
          .and_return(
            Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [other_tv])
          )
        expect(crm_client).not_to receive(:delete_tag_value)

        delete_tk_op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111").and_return(delete_tk_op)

        nx.send(:delete_subnet_tag_resources)
      end

      it "re-raises non-404 client errors" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
        )
        expect(crm_client).to receive(:list_tag_values)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:delete_subnet_tag_resources) }
          .to raise_error(Google::Apis::ClientError, /forbidden/)
      end

      it "naps when delete_tag_value raises RuntimeError for ghost bindings" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
        )

        subnet_tv = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/222", short_name: "member"
        )
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111")
          .and_return(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [subnet_tv]))
        expect(crm_client).to receive(:delete_tag_value).with("tagValues/222")
          .and_raise(RuntimeError.new("CRM operation op-1 failed: Cannot delete tag value still attached to resources in 'us-central1-a' region"))
        expect(Clog).to receive(:emit).with("Tag value still attached to resources, will retry", anything)
        expect { nx.send(:delete_subnet_tag_resources) }.to nap(15)
      end

      it "naps when delete_tag_key raises RuntimeError with FAILED_PRECONDITION" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
        )

        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111")
          .and_return(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new)
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111")
          .and_raise(RuntimeError.new("CRM operation op-1 failed: FAILED_PRECONDITION"))
        expect(Clog).to receive(:emit).with("Tag value still attached to resources, will retry", anything)
        expect { nx.send(:delete_subnet_tag_resources) }.to nap(15)
      end

      it "re-raises RuntimeError for non-ghost-binding errors" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
        )
        expect(crm_client).to receive(:list_tag_values)
          .and_raise(RuntimeError.new("CRM operation op-1 failed: INTERNAL"))

        expect { nx.send(:delete_subnet_tag_resources) }
          .to raise_error(RuntimeError, /INTERNAL/)
      end

      it "handles nil tag_values in list response" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}"
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key])
        )

        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111")
          .and_return(
            Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new
          )
        expect(crm_client).not_to receive(:delete_tag_value)

        delete_tk_op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111").and_return(delete_tk_op)

        nx.send(:delete_subnet_tag_resources)
      end
    end

    describe "#wait_for_crm_operation" do
      it "returns immediately when operation is already done" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: {"name" => "result"})
        result = nx.send(:wait_for_crm_operation, op)
        expect(result.response["name"]).to eq("result")
      end

      it "polls until done" do
        pending_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/test-op", done: false
        )
        done_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, response: {"name" => "tagKeys/polled"}
        )
        expect(crm_client).to receive(:get_operation)
          .with("operations/test-op").and_return(done_op)
        allow(nx).to receive(:sleep)

        result = nx.send(:wait_for_crm_operation, pending_op)
        expect(result.response["name"]).to eq("tagKeys/polled")
      end

      it "raises on timeout" do
        pending_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/slow-op", done: false
        )
        expect(crm_client).to receive(:get_operation).exactly(30).times.and_return(pending_op)
        allow(nx).to receive(:sleep)

        expect { nx.send(:wait_for_crm_operation, pending_op) }
          .to raise_error(RuntimeError, /operations\/slow-op.*did not complete within timeout/)
      end

      it "raises when operation completes with error" do
        error_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/err-op", done: true
        )
        error_op.error = Google::Apis::CloudresourcemanagerV3::Status.new(
          code: 7, message: "Permission denied"
        )

        expect { nx.send(:wait_for_crm_operation, error_op) }
          .to raise_error(RuntimeError, /Permission denied/)
      end
    end
  end

  describe "#delete_vpc_network" do
    it "awaits the VPC delete operation" do
      vpc_delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-vpc")
      expect(networks_client).to receive(:delete).with(
        project: "test-gcp-project", network: vpc_name
      ).and_return(vpc_delete_op)

      done = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(global_ops_client).to receive(:get).with(
        project: "test-gcp-project", operation: "op-delete-vpc"
      ).and_return(done)

      nx.send(:delete_vpc_network)
    end
  end
end
