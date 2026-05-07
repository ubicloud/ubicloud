# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vnet::Gcp::SubnetNexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { Strand.create_with_id(ps, prog: "Vnet::Gcp::SubnetNexus", label: "start") }
  let(:project) { Project.create(name: "test-gcp-subnet") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }
  let(:credential) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }
  let(:vpc_name) { "ubicloud-#{project.ubid}-#{location.ubid}" }
  let(:gcp_vpc) {
    vpc = GcpVpc.create(
      project_id: project.id,
      location_id: location.id,
      name: vpc_name,
      network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/12345",
    )
    Strand.create_with_id(vpc, prog: "Vnet::Gcp::VpcNexus", label: "wait")
    vpc
  }
  let(:ps) {
    credential
    ps = PrivateSubnet.create(name: "ps", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26", state: "waiting", project_id: project.id, firewall_priority: 1000)
    DB[:private_subnet_gcp_vpc].insert(private_subnet_id: ps.id, gcp_vpc_id: gcp_vpc.id)
    ps
  }
  let(:subnetworks_client) { instance_double(Google::Cloud::Compute::V1::Subnetworks::Rest::Client) }
  let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }
  let(:global_ops_client) { instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client) }
  let(:region_ops_client) { instance_double(Google::Cloud::Compute::V1::RegionOperations::Rest::Client) }
  let(:done_op) { Google::Cloud::Compute::V1::Operation.new(status: :DONE) }

  before do
    allow(nx.send(:credential)).to receive_messages(
      subnetworks_client:,
      network_firewall_policies_client: nfp_client,
      global_operations_client: global_ops_client,
      region_operations_client: region_ops_client,
    )
  end

  describe "#start" do
    it "creates a GcpVpc via VpcNexus.assemble when none exists, links it, fires VPC sem, and hops to wait_vpc_ready" do
      DB[:private_subnet_gcp_vpc].where(private_subnet_id: ps.id).delete
      GcpVpc.where(project_id: project.id, location_id: location.id).destroy

      expect { nx.start }.to hop("wait_vpc_ready")
      new_vpc = GcpVpc.first(project_id: project.id, location_id: location.id)
      expect(new_vpc).not_to be_nil
      expect(DB[:private_subnet_gcp_vpc].where(private_subnet_id: ps.id).get(:gcp_vpc_id)).to eq(new_vpc.id)
      expect(new_vpc.update_firewall_rules_set?).to be(true)
    end

    it "reuses existing GcpVpc, links the subnet, fires VPC sem, and hops to wait_vpc_ready" do
      DB[:private_subnet_gcp_vpc].where(private_subnet_id: ps.id).delete

      expect { nx.start }.to hop("wait_vpc_ready")
      expect(DB[:private_subnet_gcp_vpc].where(private_subnet_id: ps.id).get(:gcp_vpc_id)).to eq(gcp_vpc.id)
      expect(GcpVpc.where(project_id: project.id, location_id: location.id).count).to eq(1)
      expect(gcp_vpc.update_firewall_rules_set?).to be(true)
    end

    it "does not re-fire the VPC sem when the subnet is already linked" do
      expect { nx.start }.to hop("wait_vpc_ready")
      expect(gcp_vpc.update_firewall_rules_set?).to be(false)
    end
  end

  describe "#wait_vpc_ready" do
    it "hops to create_subnet when VPC strand is in wait state" do
      expect { nx.wait_vpc_ready }.to hop("create_subnet")
    end

    it "naps when VPC strand is not in wait state" do
      gcp_vpc.strand.update(label: "create_vpc")
      expect { nx.wait_vpc_ready }.to nap(5)
    end
  end

  describe "#create_subnet" do
    it "skips creation if subnet already exists" do
      expect(subnetworks_client).to receive(:insert).and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(Clog).to receive(:emit).with("GCP subnet created", hash_including(gcp_subnet_created: "ubicloud-#{ps.ubid}@us-central1")).and_call_original

      expect { nx.create_subnet }.to hop("create_tag_resources")
    end

    it "creates dual-stack subnet and hops to wait_create_subnet" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-subnet-123")
      expect(Config).to receive(:provider_resource_tag_value).and_return("2024")
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
        expect(sr.description).to include("[Ubicloud=2024]")
        op
      end

      expect { nx.create_subnet }.to hop("wait_create_subnet")
      expect(st.stack.first.dig("create_subnet", "name")).to eq("op-subnet-123")
    end
  end

  describe "#wait_create_subnet" do
    before do
      refresh_frame(nx, new_values: {"create_subnet" => {"name" => "op-subnet-123", "scope" => "region", "scope_value" => "us-central1"}})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(region_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_create_subnet }.to nap(5)
    end

    it "hops to create_tag_resources when operation completes" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(region_ops_client).to receive(:get).and_return(op)
      expect(Clog).to receive(:emit).with("GCP subnet created", hash_including(gcp_subnet_created: "ubicloud-#{ps.ubid}@us-central1")).and_call_original
      expect { nx.wait_create_subnet }.to hop("create_tag_resources")
    end

    it "raises if subnet creation fails" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
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
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
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
      allow(nx.send(:credential)).to receive(:crm_client).and_return(crm_client)
      stub_fetch_all_via_list(crm_client)
    end

    it "creates tag key and tag value, stores in frame, and hops to create_subnet_allow_rules" do
      tag_key_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, response: {"name" => "tagKeys/111"},
      )
      expect(crm_client).to receive(:create_tag_key).and_return(tag_key_op)

      tag_value_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, response: {"name" => "tagValues/222"},
      )
      expect(crm_client).to receive(:create_tag_value).and_return(tag_value_op)

      expect(Clog).to receive(:emit).with("GCP tag key created", hash_including(gcp_tag_key_created: "tagKeys/111")).and_call_original
      expect(Clog).to receive(:emit).with("GCP tag value created", hash_including(gcp_tag_value_created: "tagValues/222")).and_call_original

      expect { nx.create_tag_resources }.to hop("create_subnet_allow_rules")
      expect(st.stack.first["tag_key_name"]).to eq("tagKeys/111")
      expect(st.stack.first["subnet_tag_value_name"]).to eq("tagValues/222")
    end

    it "handles existing tag key (409 conflict) and creates tag value" do
      expect(crm_client).to receive(:create_tag_key)
        .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))

      existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/existing", short_name: "ubicloud-subnet-#{ps.ubid}",
      )
      resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key])
      expect(crm_client).to receive(:list_tag_keys).and_return(resp)

      tag_value_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, response: {"name" => "tagValues/333"},
      )
      expect(crm_client).to receive(:create_tag_value).and_return(tag_value_op)

      expect(Clog).to receive(:emit).with("GCP tag key created", hash_including(gcp_tag_key_created: "tagKeys/existing")).and_call_original
      expect(Clog).to receive(:emit).with("GCP tag value created", hash_including(gcp_tag_value_created: "tagValues/333")).and_call_original

      expect { nx.create_tag_resources }.to hop("create_subnet_allow_rules")
      expect(st.stack.first["tag_key_name"]).to eq("tagKeys/existing")
      expect(st.stack.first["subnet_tag_value_name"]).to eq("tagValues/333")
    end

    it "naps when CRM tag key operation is not done and saves pending op in frame" do
      pending_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        name: "operations/tk-create", done: false,
      )
      expect(crm_client).to receive(:create_tag_key).and_return(pending_op)

      expect { nx.create_tag_resources }.to nap(5)
      expect(st.stack.first["pending_tag_key_crm_op"]).to eq("operations/tk-create")
    end

    it "polls pending tag key operation on re-entry and proceeds to create tag value" do
      refresh_frame(nx, new_values: {"pending_tag_key_crm_op" => "operations/tk-create"})

      done_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, name: "operations/tk-create", response: {"name" => "tagKeys/polled-1"},
      )
      expect(crm_client).to receive(:get_operation).with("operations/tk-create").and_return(done_op)

      tag_value_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true, response: {"name" => "tagValues/222"},
      )
      expect(crm_client).to receive(:create_tag_value).and_return(tag_value_op)

      expect(Clog).to receive(:emit).with("GCP tag key created", hash_including(gcp_tag_key_created: "tagKeys/polled-1")).and_call_original
      expect(Clog).to receive(:emit).with("GCP tag value created", hash_including(gcp_tag_value_created: "tagValues/222")).and_call_original

      expect { nx.create_tag_resources }.to hop("create_subnet_allow_rules")
      expect(st.stack.first["tag_key_name"]).to eq("tagKeys/polled-1")
      expect(st.stack.first["subnet_tag_value_name"]).to eq("tagValues/222")
    end

    it "naps when CRM tag value operation is not done and saves pending op in frame" do
      # Tag key already completed and saved in frame
      refresh_frame(nx, new_values: {"tag_key_name" => "tagKeys/111"})

      pending_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        name: "operations/tv-create", done: false,
      )
      expect(crm_client).to receive(:create_tag_value).and_return(pending_op)
      # Re-entry still emits the tag key name so a strand that crashed
      # mid-way still has every created resource grep-able from foreman.log.
      expect(Clog).to receive(:emit).with("GCP tag key created", hash_including(gcp_tag_key_created: "tagKeys/111")).and_call_original

      expect { nx.create_tag_resources }.to nap(5)
      expect(st.stack.first["pending_tag_value_crm_op"]).to eq("operations/tv-create")
    end
  end

  describe "#create_subnet_allow_rules" do
    let(:subnet_tag_value_name) { "tagValues/222" }

    before do
      refresh_frame(nx, new_values: {"subnet_tag_value_name" => subnet_tag_value_name})
    end

    it "creates IPv4+IPv6 tag-based egress allow rules (fire-and-forget)" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      created_rules = []
      expect(nfp_client).to receive(:add_rule).twice do |args|
        rule = args[:firewall_policy_rule_resource]
        created_rules << {
          direction: rule.direction,
          action: rule.action,
          dest_ip_ranges: rule.match.dest_ip_ranges.to_a,
          target_secure_tags: rule.target_secure_tags.map(&:name),
        }
        instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      end

      expect { nx.create_subnet_allow_rules }.to hop("wait")

      expect(created_rules).to all(include(direction: "EGRESS", action: "allow"))
      created_rules.each do |r|
        expect(r[:dest_ip_ranges]).not_to be_empty
        expect(r[:target_secure_tags]).to eq([subnet_tag_value_name])
      end
    end

    it "swallows AlreadyExistsError from add_rule (concurrent strand)" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:add_rule).twice
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))

      expect { nx.create_subnet_allow_rules }.to hop("wait")
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
              layer4_configs: [all_proto],
            ),
            target_secure_tags: [tag],
          )
        else
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "EGRESS", action: "allow",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              dest_ip_ranges: [net6],
              layer4_configs: [all_proto],
            ),
            target_secure_tags: [tag],
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
          layer4_configs: [tcp_proto],
        ),
        target_secure_tags: [tag],
      )
      wrong_proto_rule6 = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [net6],
          layer4_configs: [tcp_proto],
        ),
        target_secure_tags: [tag],
      )
      expect(nfp_client).to receive(:get_rule).twice do |args|
        args[:priority].even? ? wrong_proto_rule : wrong_proto_rule6
      end

      expect(nfp_client).to receive(:patch_rule).twice
        .and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-rule"))
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, overwriting rule", anything).twice.and_call_original

      expect { nx.create_subnet_allow_rules }.to hop("wait")
    end

    it "overwrites foreign rule on priority collision and logs warning" do
      foreign_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.99.0.0/24"],
        ),
      )
      expect(nfp_client).to receive(:get_rule).twice.and_return(foreign_rule)

      expect(nfp_client).to receive(:patch_rule).twice
        .and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-rule"))

      expect(Clog).to receive(:emit).with("GCP firewall priority collision, overwriting rule", anything).twice.and_call_original

      expect { nx.create_subnet_allow_rules }.to hop("wait")
    end

    it "allocates firewall_priority when not yet set" do
      nx.private_subnet.update(firewall_priority: nil)

      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:add_rule).twice
        .and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-rule"))

      expect { nx.create_subnet_allow_rules }.to hop("wait")
      expect(ps.reload.firewall_priority).to eq(1000)
    end
  end

  describe "#allocate_subnet_firewall_priority" do
    before do
      nx.private_subnet.update(firewall_priority: nil)
    end

    it "allocates the lowest available even slot starting at 1000" do
      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1000)
    end

    it "gap-fills: uses lowest available slot when 1000 is taken" do
      other_ps = PrivateSubnet.create(name: "ps2", location_id: location.id, net6: "fd11::/64",
        net4: "10.0.1.0/26", state: "waiting", project_id: project.id, firewall_priority: 1000)
      DB[:private_subnet_gcp_vpc].insert(private_subnet_id: other_ps.id, gcp_vpc_id: gcp_vpc.id)

      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1002)

      other_ps.destroy
    end

    it "gap-fills when middle slot is free" do
      ps1 = PrivateSubnet.create(name: "ps1", location_id: location.id, net6: "fd11::/64",
        net4: "10.0.1.0/26", state: "waiting", project_id: project.id, firewall_priority: 1000)
      DB[:private_subnet_gcp_vpc].insert(private_subnet_id: ps1.id, gcp_vpc_id: gcp_vpc.id)
      ps3 = PrivateSubnet.create(name: "ps3", location_id: location.id, net6: "fd12::/64",
        net4: "10.0.2.0/26", state: "waiting", project_id: project.id, firewall_priority: 1004)
      DB[:private_subnet_gcp_vpc].insert(private_subnet_id: ps3.id, gcp_vpc_id: gcp_vpc.id)

      nx.send(:allocate_subnet_firewall_priority)
      expect(ps.reload.firewall_priority).to eq(1002)

      ps1.destroy
      ps3.destroy
    end

    it "raises when all slots are exhausted" do
      ds = DB.from { generate_series(1000, 8998, 2).as(:private_subnet, [:firewall_priority]) }
      expect(nx).to receive(:used_firewall_priorities_ds).and_return(ds)

      expect { nx.send(:allocate_subnet_firewall_priority) }
        .to raise_error(RuntimeError, /GCP firewall priority range exhausted for project/)
    end
  end

  describe "#wait" do
    it "naps" do
      expect { nx.wait }.to nap(10 * 60)
    end

    it "clears refresh_keys semaphore when set" do
      nx.incr_refresh_keys
      expect { nx.wait }.to nap(10 * 60)
      expect(Semaphore.where(strand_id: st.id, name: "refresh_keys").count).to eq(0)
    end

    it "propagates update_firewall_rules to the VPC and clears the subnet semaphore" do
      nx.incr_update_firewall_rules
      expect { nx.wait }.to nap(10 * 60)
      expect(Semaphore.where(strand_id: st.id, name: "update_firewall_rules").count).to eq(0)
      expect(Semaphore.where(strand_id: gcp_vpc.id, name: "update_firewall_rules").count).to eq(1)
    end
  end

  describe "#destroy" do
    let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }

    before do
      allow(nx.send(:credential)).to receive(:crm_client).and_return(crm_client)
      stub_fetch_all_via_list(crm_client)
      # Default: no tag key found (skip tag cleanup)
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )
    end

    it "fires delete op and hops to wait_delete_subnet" do
      # delete_subnet_policy_rules: rules already deleted.
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      # delete_gcp_subnet: fires op.
      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).with(
        project: "test-gcp-project",
        region: "us-central1",
        subnetwork: "ubicloud-#{ps.ubid}",
      ).and_return(delete_op)

      expect { nx.destroy }.to hop("wait_delete_subnet")
      expect(st.reload.stack.first.dig("delete_subnet", "name")).to eq("op-delete-subnet")
    end

    it "cleans up tag value and tag key (per-subnet)" do
      # delete_subnet_policy_rules
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      # delete_subnet_tag_resources: per-subnet tag key.
      tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
      )
      expect(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
      )

      subnet_tv = Google::Apis::CloudresourcemanagerV3::TagValue.new(
        name: "tagValues/222", short_name: "active",
      )
      expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111", page_token: nil)
        .and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [subnet_tv]),
        )

      expect(crm_client).to receive(:delete_tag_value).with("tagValues/222")
      expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111")

      # delete_gcp_subnet
      expect(subnetworks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.destroy }.to hop("finish_destroy")
    end

    it "handles 404 during tag cleanup" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      # Tag key exists but list_tag_values raises 404
      tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
      )
      expect(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
      )
      expect(crm_client).to receive(:list_tag_values)
        .and_raise(Google::Apis::ClientError.new("not found", status_code: 404))

      expect(subnetworks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect { nx.destroy }.to hop("finish_destroy")
    end

    it "skips deleting rules that belong to a foreign subnet (collision)" do
      # get_rule returns a rule belonging to a different subnet
      foreign_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: ["10.99.0.0/24"],
        ),
      )
      expect(nfp_client).to receive(:get_rule).twice.and_return(foreign_rule)
      expect(nfp_client).not_to receive(:remove_rule)

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)

      expect { nx.destroy }.to hop("wait_delete_subnet")
    end

    it "handles already-deleted GCP subnet" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect { nx.destroy }.to hop("finish_destroy")
    end

    it "naps when GCE subnet is still in use by a terminating instance" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(
        Google::Cloud::InvalidArgumentError.new("The subnetwork resource is already being used by 'projects/test/instances/vm-1'"),
      )
      expect { nx.destroy }.to nap(5)
    end

    it "re-raises InvalidArgumentError when not about subnet being used" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(subnetworks_client).to receive(:delete).and_raise(
        Google::Cloud::InvalidArgumentError.new("Invalid CIDR range"),
      )
      expect { nx.destroy }.to raise_error(Google::Cloud::InvalidArgumentError)
    end

    it "skips rule deletion when firewall_priority is nil (early destroy)" do
      nx.private_subnet.update(firewall_priority: nil)
      expect(nfp_client).not_to receive(:get_rule)
      expect(nfp_client).not_to receive(:remove_rule)

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)

      expect { nx.destroy }.to hop("wait_delete_subnet")
    end

    it "destroys nics and load balancers first" do
      vm = create_vm(project_id: project.id, location_id: location.id)
      Strand.create_with_id(vm, prog: "Vm::Nexus", label: "wait")
      nic = Nic.create(private_subnet_id: ps.id, private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
        private_ipv4: "10.0.0.5", mac: "00:00:00:00:00:00",
        encryption_key: "0x736f6d655f656e6372797074696f6e5f6b6579",
        name: "default-nic", vm_id: vm.id, state: "active")
      Strand.create_with_id(nic, prog: "Vnet::NicNexus", label: "wait")
      lb = LoadBalancer.create(name: "test-lb", health_check_endpoint: "/",
        project_id: project.id, private_subnet_id: ps.id)
      Strand.create_with_id(lb, prog: "Vnet::LoadBalancerNexus", label: "wait")

      expect(nx).to receive(:rand).with(5..10).and_return(7)
      expect { nx.destroy }.to nap(7)

      expect(Semaphore.where(strand_id: nic.id, name: "destroy").any?).to be true
      expect(Semaphore.where(strand_id: lb.id, name: "destroy").any?).to be true
    end

    it "handles policy not found during rule cleanup" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)

      expect { nx.destroy }.to hop("wait_delete_subnet")
    end

    it "handles InvalidArgumentError during rule cleanup" do
      expect(nfp_client).to receive(:get_rule).twice
        .and_raise(Google::Cloud::InvalidArgumentError.new("does not contain a rule"))

      delete_op = instance_double(Gapic::GenericLRO::Operation, name: "op-delete-subnet")
      expect(subnetworks_client).to receive(:delete).and_return(delete_op)

      expect { nx.destroy }.to hop("wait_delete_subnet")
    end
  end

  describe "#wait_delete_subnet" do
    before do
      refresh_frame(nx, new_values: {"delete_subnet" => {"name" => "op-delete-subnet", "scope" => "region", "scope_value" => "us-central1"}})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(region_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_delete_subnet }.to nap(5)
    end

    it "hops to finish_destroy when operation completes" do
      expect(region_ops_client).to receive(:get).and_return(done_op)
      expect { nx.wait_delete_subnet }.to hop("finish_destroy")
    end

    it "logs and proceeds when LRO errors but subnet is already gone" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(region_ops_client).to receive(:get).and_return(op)
      expect(subnetworks_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(Clog).to receive(:emit).with("GCP subnet already gone despite LRO error; proceeding", anything).and_call_original

      expect { nx.wait_delete_subnet }.to hop("finish_destroy")
    end

    it "raises when LRO errors and subnet is still present" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(region_ops_client).to receive(:get).and_return(op)
      expect(subnetworks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Subnetwork.new(name: "ubicloud-#{ps.ubid}"))

      expect { nx.wait_delete_subnet }.to raise_error(RuntimeError, /deletion LRO failed.*still present/)
    end
  end

  describe "#finish_destroy" do
    it "destroys the subnet and pops" do
      # Create another subnet so gcp_vpc is not the last
      ps2 = PrivateSubnet.create(name: "ps2", location_id: location.id, net6: "fd10:9b0b:6b4b:8fbc::/64",
        net4: "10.0.1.0/26", state: "waiting", project_id: project.id)
      DB[:private_subnet_gcp_vpc].insert(private_subnet_id: ps2.id, gcp_vpc_id: gcp_vpc.id)

      expect { nx.finish_destroy }.to exit({"msg" => "subnet destroyed"})
      expect(ps.exists?).to be false
      # VPC should not be marked for destruction since other subnets exist
      expect(Semaphore.where(strand_id: gcp_vpc.id, name: "destroy").count).to eq(0)
    end

    it "cleans up VPC via incr_destroy when last subnet destroyed" do
      expect { nx.finish_destroy }.to exit({"msg" => "subnet destroyed"})
      expect(ps.exists?).to be false
      expect(Semaphore.where(strand_id: gcp_vpc.id, name: "destroy").count).to eq(1)
    end

    it "handles nil gcp_vpc gracefully" do
      DB[:private_subnet_gcp_vpc].where(private_subnet_id: ps.id).delete
      nx.private_subnet.refresh

      expect { nx.finish_destroy }.to exit({"msg" => "subnet destroyed"})
      expect(ps.exists?).to be false
    end
  end

  describe "#firewall_policy_rule_matches_desired?" do
    it "returns false and covers nil-match &. branches when existing.match is nil" do
      rule_no_match = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "deny",
      )
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      result = nx.send(:firewall_policy_rule_matches_desired?, rule_no_match,
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
          layer4_configs: [all_proto],
        ),
        target_secure_tags: [tag],
      )
      result = nx.send(:firewall_policy_rule_matches_desired?, rule,
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
          layer4_configs: [all_proto],
        ),
        target_secure_tags: [tag],
      )
      result = nx.send(:firewall_policy_rule_matches_desired?, rule,
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
          layer4_configs: [all_proto],
        ),
      )
      result = nx.send(:firewall_policy_rule_matches_desired?, rule,
        direction: "EGRESS", action: "deny",
        src_ip_ranges: nil, dest_ip_ranges: ["10.0.0.0/8"],
        layer4_configs: [all_proto])
      expect(result).to be(true)
    end
  end

  describe "#ensure_firewall_policy_rule" do
    it "handles src_ip_ranges without dest_ip_ranges or target_secure_tags" do
      expect(nfp_client).to receive(:get_rule)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.match.src_ip_ranges.to_a).to eq(["10.0.0.0/8"])
        expect(rule.match.layer4_configs.first.ip_protocol).to eq("all")
        expect(rule.target_secure_tags.to_a).to be_empty
      end

      nx.send(:ensure_firewall_policy_rule,
        priority: 50000,
        direction: "INGRESS",
        action: "deny",
        layer4_configs: [{ip_protocol: "all"}],
        src_ip_ranges: ["10.0.0.0/8"])
    end
  end

  describe "#normalize_layer4_configs" do
    it "normalizes layer4 configs with no ports" do
      config = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "tcp")
      result = nx.send(:normalize_layer4_configs, [config])
      expect(result).to eq([["tcp", []]])
    end
  end

  describe "#delete_subnet_policy_rules" do
    it "skips rule when existing rule has nil match (covers &.dest_ip_ranges nil branch)" do
      rule_no_match = Google::Cloud::Compute::V1::FirewallPolicyRule.new
      expect(nfp_client).to receive(:get_rule).twice.and_return(rule_no_match)
      expect(nfp_client).not_to receive(:remove_rule)

      nx.send(:delete_subnet_policy_rules)
    end

    it "removes rules that match this subnet's CIDRs" do
      matching_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          dest_ip_ranges: [ps.net4.to_s],
        ),
      )
      expect(nfp_client).to receive(:get_rule).twice.and_return(matching_rule)
      expect(nfp_client).to receive(:remove_rule).twice

      nx.send(:delete_subnet_policy_rules)
    end
  end

  describe "secure tag helpers" do
    let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }

    before do
      allow(nx.send(:credential)).to receive(:crm_client).and_return(crm_client)
      stub_fetch_all_via_list(crm_client)
    end

    describe "#tag_key_short_name" do
      it "returns ubicloud-subnet-<private_subnet_ubid>" do
        expect(nx.send(:tag_key_short_name)).to eq("ubicloud-subnet-#{ps.ubid}")
      end
    end

    describe "#tag_key_parent" do
      it "returns projects/<gcp_project_id>" do
        expect(nx.send(:tag_key_parent)).to eq("projects/test-gcp-project")
      end
    end

    describe "#lookup_tag_value_name" do
      it "returns nil when tag_values is nil in the response" do
        resp = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/123", page_token: nil).and_return(resp)

        expect(nx.send(:lookup_tag_value_name, "tagKeys/123", "active")).to be_nil
      end

      it "paginates list_tag_values to find the target on a later page" do
        page1 = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
          tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/p1", short_name: "stale")],
          next_page_token: "tv-tok",
        )
        page2 = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
          tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/page2", short_name: "active")],
        )
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/123", page_token: nil).ordered.and_return(page1)
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/123", page_token: "tv-tok").ordered.and_return(page2)

        expect(nx.send(:lookup_tag_value_name, "tagKeys/123", "active")).to eq("tagValues/page2")
      end
    end

    describe "#delete_subnet_tag_resources" do
      it "returns early when no tag key exists" do
        resp = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [])
        expect(crm_client).to receive(:list_tag_keys).and_return(resp)
        expect(crm_client).not_to receive(:list_tag_values)

        nx.send(:delete_subnet_tag_resources)
      end

      it "paginates list_tag_values to find subnet tag value on page 2" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )

        page1 = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
          tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/other", short_name: "stale")],
          next_page_token: "del-tok",
        )
        page2 = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
          tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/active-on-page-2", short_name: "active")],
        )
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/111", page_token: nil).ordered.and_return(page1)
        expect(crm_client).to receive(:list_tag_values)
          .with(parent: "tagKeys/111", page_token: "del-tok").ordered.and_return(page2)

        expect(crm_client).to receive(:delete_tag_value).with("tagValues/active-on-page-2")
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111")

        nx.send(:delete_subnet_tag_resources)
      end

      it "skips tag value deletion when member tag value not found but still deletes key" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )

        other_tv = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/333", short_name: "other",
        )
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111", page_token: nil)
          .and_return(
            Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [other_tv]),
          )
        expect(crm_client).not_to receive(:delete_tag_value)
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111")

        nx.send(:delete_subnet_tag_resources)
      end

      it "handles nil tag_values in list response" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )

        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111", page_token: nil)
          .and_return(
            Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new,
          )
        expect(crm_client).not_to receive(:delete_tag_value)
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111")

        nx.send(:delete_subnet_tag_resources)
      end

      it "naps when delete_tag_value fails with FAILED_PRECONDITION (still attached)" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )

        subnet_tv = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/222", short_name: "active",
        )
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111", page_token: nil)
          .and_return(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [subnet_tv]))
        body = {error: {code: 400, status: "FAILED_PRECONDITION", message: "Cannot delete tag value still attached to resources"}}.to_json
        expect(crm_client).to receive(:delete_tag_value).with("tagValues/222")
          .and_raise(Google::Apis::ClientError.new("FAILED_PRECONDITION: still attached", status_code: 400, body:))
        expect(Clog).to receive(:emit).with("Tag value still attached to resources, will retry", anything).and_call_original
        expect { nx.send(:delete_subnet_tag_resources) }.to nap(15)
      end

      it "naps when delete_tag_key fails with FAILED_PRECONDITION" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )

        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/111", page_token: nil)
          .and_return(Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new)
        body = {error: {code: 400, status: "FAILED_PRECONDITION", message: "Tag key has children"}}.to_json
        expect(crm_client).to receive(:delete_tag_key).with("tagKeys/111")
          .and_raise(Google::Apis::ClientError.new("FAILED_PRECONDITION: has children", status_code: 400, body:))
        expect(Clog).to receive(:emit).with("Tag value still attached to resources, will retry", anything).and_call_original
        expect { nx.send(:delete_subnet_tag_resources) }.to nap(15)
      end

      it "re-raises 400 errors that are not FAILED_PRECONDITION" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )
        body = {error: {code: 400, status: "INVALID_ARGUMENT", message: "bad request"}}.to_json
        expect(crm_client).to receive(:list_tag_values)
          .and_raise(Google::Apis::ClientError.new("INVALID_ARGUMENT: bad request", status_code: 400, body:))

        expect { nx.send(:delete_subnet_tag_resources) }
          .to raise_error(Google::Apis::ClientError, /INVALID_ARGUMENT/)
      end

      it "re-raises 400 errors whose body has no parseable JSON" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )
        expect(crm_client).to receive(:list_tag_values)
          .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400, body: "not json"))

        expect { nx.send(:delete_subnet_tag_resources) }
          .to raise_error(Google::Apis::ClientError, /bad request/)
      end

      it "re-raises 400 errors with an empty body" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )
        expect(crm_client).to receive(:list_tag_values)
          .and_raise(Google::Apis::ClientError.new("bad request", status_code: 400, body: ""))

        expect { nx.send(:delete_subnet_tag_resources) }
          .to raise_error(Google::Apis::ClientError, /bad request/)
      end

      it "re-raises non-404 client errors" do
        tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/111", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [tag_key]),
        )
        expect(crm_client).to receive(:list_tag_values)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:delete_subnet_tag_resources) }
          .to raise_error(Google::Apis::ClientError, /forbidden/)
      end
    end

    describe "tag resource description stamping" do
      let(:done_op) {
        Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tag-op", response: {"name" => "tagKeys/abc"},
        )
      }

      it "stamps tag key description with Config.provider_resource_tag_value" do
        expect(Config).to receive(:provider_resource_tag_value).and_return("9090")
        expect(crm_client).to receive(:create_tag_key) do |tag_key|
          expect(tag_key.description).to eq("Ubicloud subnet tag key [Ubicloud=9090]")
          done_op
        end
        nx.send(:ensure_tag_key)
      end

      it "stamps tag value description with Config.provider_resource_tag_value" do
        expect(Config).to receive(:provider_resource_tag_value).and_return("9090")
        value_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tag-op", response: {"name" => "tagValues/xyz"},
        )
        expect(crm_client).to receive(:create_tag_value) do |tag_value|
          expect(tag_value.description).to eq("Ubicloud subnet tag value [Ubicloud=9090]")
          value_op
        end
        nx.send(:ensure_tag_value, "tagKeys/123", "active")
      end
    end

    describe "#ensure_tag_key" do
      it "falls back to lookup when operation response has no name" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/fallback", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key]),
        )

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/fallback")
      end

      it "handles ALREADY_EXISTS CRM LRO error via op.error.code" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 6, message: "tag key already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, error:)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/existing", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key]),
        )

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/existing")
      end

      it "paginates list_tag_keys to find target on page 2 after ALREADY_EXISTS" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 6, message: "tag key already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, error:)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        page1 = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(
          tag_keys: [Google::Apis::CloudresourcemanagerV3::TagKey.new(name: "tagKeys/other", short_name: "ubicloud-subnet-other")],
          next_page_token: "subnet-tok",
        )
        page2 = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(
          tag_keys: [Google::Apis::CloudresourcemanagerV3::TagKey.new(name: "tagKeys/page2", short_name: "ubicloud-subnet-#{ps.ubid}")],
        )
        expect(crm_client).to receive(:list_tag_keys)
          .with(parent: "projects/test-gcp-project", page_token: nil).ordered.and_return(page1)
        expect(crm_client).to receive(:list_tag_keys)
          .with(parent: "projects/test-gcp-project", page_token: "subnet-tok").ordered.and_return(page2)

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/page2")
      end

      it "raises when response has no name and lookup returns nil" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_key).and_return(op)
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: nil),
        )

        expect { nx.send(:ensure_tag_key) }.to raise_error(RuntimeError, /created but name not found/)
      end

      it "raises when 409 conflict and lookup returns nil" do
        expect(crm_client).to receive(:create_tag_key)
          .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
        )

        expect { nx.send(:ensure_tag_key) }.to raise_error(RuntimeError, /conflict but not found/)
      end

      it "raises when ALREADY_EXISTS and lookup returns nil" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 6, message: "tag key already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, error:)
        expect(crm_client).to receive(:create_tag_key).and_return(op)
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
        )

        expect { nx.send(:ensure_tag_key) }.to raise_error(RuntimeError, /conflict but not found/)
      end

      it "re-raises non-ALREADY_EXISTS CrmOperationError" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 13, message: "server error")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, error:)
        expect(crm_client).to receive(:create_tag_key).and_return(op)

        expect { nx.send(:ensure_tag_key) }.to raise_error(described_class::CrmOperationError, /server error/)
      end

      it "re-raises non-409 ClientError" do
        expect(crm_client).to receive(:create_tag_key)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:ensure_tag_key) }.to raise_error(Google::Apis::ClientError, /forbidden/)
      end

      it "naps when create operation is not done and saves pending op" do
        pending_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/tk-pending", done: false,
        )
        expect(crm_client).to receive(:create_tag_key).and_return(pending_op)

        expect { nx.send(:ensure_tag_key) }.to nap(5)
        expect(st.stack.first["pending_tag_key_crm_op"]).to eq("operations/tk-pending")
      end

      it "polls pending op on re-entry and returns name" do
        refresh_frame(nx, new_values: {"pending_tag_key_crm_op" => "operations/tk-poll"})

        done_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tk-poll", response: {"name" => "tagKeys/polled"},
        )
        expect(crm_client).to receive(:get_operation).with("operations/tk-poll").and_return(done_op)

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/polled")
      end

      it "naps again when polling pending op that is still not done" do
        refresh_frame(nx, new_values: {"pending_tag_key_crm_op" => "operations/tk-still-pending"})

        still_pending = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/tk-still-pending", done: false,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tk-still-pending").and_return(still_pending)

        expect { nx.send(:ensure_tag_key) }.to nap(5)
      end

      it "raises when polled pending op has error" do
        refresh_frame(nx, new_values: {"pending_tag_key_crm_op" => "operations/tk-error"})

        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 13, message: "server error")
        error_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tk-error", error:,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tk-error").and_return(error_op)

        expect { nx.send(:ensure_tag_key) }.to raise_error(described_class::CrmOperationError, /server error/)
      end

      it "falls back to lookup when polled pending op has no name in response" do
        refresh_frame(nx, new_values: {"pending_tag_key_crm_op" => "operations/tk-no-name"})

        no_name_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tk-no-name", response: nil,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tk-no-name").and_return(no_name_op)

        existing_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
          name: "tagKeys/fallback-poll", short_name: "ubicloud-subnet-#{ps.ubid}",
        )
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [existing_key]),
        )

        expect(nx.send(:ensure_tag_key)).to eq("tagKeys/fallback-poll")
      end

      it "raises when polled pending op has no name and lookup returns nil" do
        refresh_frame(nx, new_values: {"pending_tag_key_crm_op" => "operations/tk-no-name-nil"})

        no_name_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tk-no-name-nil", response: nil,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tk-no-name-nil").and_return(no_name_op)
        expect(crm_client).to receive(:list_tag_keys).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
        )

        expect { nx.send(:ensure_tag_key) }.to raise_error(RuntimeError, /created but name not found/)
      end
    end

    describe "#ensure_tag_value" do
      it "falls back to lookup when operation response has no name" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_value).and_return(op)
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123", page_token: nil).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
            tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/fallback", short_name: "active")],
          ),
        )

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/fallback")
      end

      it "handles 409 conflict by looking up existing tag value" do
        expect(crm_client).to receive(:create_tag_value)
          .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123", page_token: nil).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
            tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/existing", short_name: "active")],
          ),
        )

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/existing")
      end

      it "handles ALREADY_EXISTS CRM LRO error via op.error.code" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 6, message: "tag value already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, error:)
        expect(crm_client).to receive(:create_tag_value).and_return(op)
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123", page_token: nil).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
            tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/existing", short_name: "active")],
          ),
        )

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/existing")
      end

      it "raises when response nil and lookup returns nil" do
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, response: nil)
        expect(crm_client).to receive(:create_tag_value).and_return(op)
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123", page_token: nil).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: []),
        )

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(RuntimeError, /created but name not found/)
      end

      it "raises when 409 conflict and lookup returns nil" do
        expect(crm_client).to receive(:create_tag_value)
          .and_raise(Google::Apis::ClientError.new("conflict", status_code: 409))
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123", page_token: nil).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: []),
        )

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(RuntimeError, /conflict but not found/)
      end

      it "raises when ALREADY_EXISTS and lookup returns nil" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 6, message: "tag value already exists")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, error:)
        expect(crm_client).to receive(:create_tag_value).and_return(op)
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123", page_token: nil).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: []),
        )

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(RuntimeError, /conflict but not found/)
      end

      it "re-raises non-ALREADY_EXISTS CrmOperationError" do
        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 13, message: "server error")
        op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true, error:)
        expect(crm_client).to receive(:create_tag_value).and_return(op)

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(described_class::CrmOperationError, /server error/)
      end

      it "re-raises non-409 ClientError" do
        expect(crm_client).to receive(:create_tag_value)
          .and_raise(Google::Apis::ClientError.new("forbidden", status_code: 403))

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(Google::Apis::ClientError, /forbidden/)
      end

      it "naps when create operation is not done and saves pending op" do
        pending_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/tv-pending", done: false,
        )
        expect(crm_client).to receive(:create_tag_value).and_return(pending_op)

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
        expect(st.stack.first["pending_tag_value_crm_op"]).to eq("operations/tv-pending")
      end

      it "polls pending op on re-entry and returns name" do
        refresh_frame(nx, new_values: {"pending_tag_value_crm_op" => "operations/tv-poll"})

        done_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tv-poll", response: {"name" => "tagValues/polled"},
        )
        expect(crm_client).to receive(:get_operation).with("operations/tv-poll").and_return(done_op)

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/polled")
      end

      it "naps again when polling pending op that is still not done" do
        refresh_frame(nx, new_values: {"pending_tag_value_crm_op" => "operations/tv-still-pending"})

        still_pending = Google::Apis::CloudresourcemanagerV3::Operation.new(
          name: "operations/tv-still-pending", done: false,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tv-still-pending").and_return(still_pending)

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to nap(5)
      end

      it "falls back to lookup when polled pending op has no name in response" do
        refresh_frame(nx, new_values: {"pending_tag_value_crm_op" => "operations/tv-no-name"})

        no_name_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tv-no-name", response: nil,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tv-no-name").and_return(no_name_op)

        existing_value = Google::Apis::CloudresourcemanagerV3::TagValue.new(
          name: "tagValues/fallback-poll", short_name: "active",
        )
        expect(crm_client).to receive(:list_tag_values).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [existing_value]),
        )

        expect(nx.send(:ensure_tag_value, "tagKeys/123", "active")).to eq("tagValues/fallback-poll")
      end

      it "raises when polled pending op has no name and lookup returns nil" do
        refresh_frame(nx, new_values: {"pending_tag_value_crm_op" => "operations/tv-no-name-nil"})

        no_name_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tv-no-name-nil", response: nil,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tv-no-name-nil").and_return(no_name_op)
        expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/123", page_token: nil).and_return(
          Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: []),
        )

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(RuntimeError, /created but name not found/)
      end

      it "raises when polled pending op has error" do
        refresh_frame(nx, new_values: {"pending_tag_value_crm_op" => "operations/tv-error"})

        error = Google::Apis::CloudresourcemanagerV3::Status.new(code: 13, message: "server error")
        error_op = Google::Apis::CloudresourcemanagerV3::Operation.new(
          done: true, name: "operations/tv-error", error:,
        )
        expect(crm_client).to receive(:get_operation).with("operations/tv-error").and_return(error_op)

        expect { nx.send(:ensure_tag_value, "tagKeys/123", "active") }.to raise_error(described_class::CrmOperationError, /server error/)
      end
    end
  end
end
