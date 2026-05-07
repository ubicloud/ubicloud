# frozen_string_literal: true

require "google/cloud/compute/v1"
require "google/apis/cloudresourcemanager_v3"
require "googleauth"

RSpec.describe Prog::Vnet::Gcp::VpcNexus do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-gcp-vpc") }
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
  let(:gcp_vpc) {
    credential
    GcpVpc.create(
      project_id: project.id,
      location_id: location.id,
      name: "ubicloud-#{project.ubid}-#{location.ubid}",
    )
  }
  let(:st) { Strand.create_with_id(gcp_vpc, prog: "Vnet::Gcp::VpcNexus", label: "start") }
  let(:vpc_name) { gcp_vpc.name }
  let(:networks_client) { instance_double(Google::Cloud::Compute::V1::Networks::Rest::Client) }
  let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }
  let(:global_ops_client) { instance_double(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client) }
  let(:crm_client) { instance_double(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService) }
  let(:done_op) { Google::Cloud::Compute::V1::Operation.new(status: :DONE) }

  before do
    allow(Google::Cloud::Compute::V1::Networks::Rest::Client).to receive(:new).and_return(networks_client)
    allow(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client).to receive(:new).and_return(nfp_client)
    allow(Google::Cloud::Compute::V1::GlobalOperations::Rest::Client).to receive(:new).and_return(global_ops_client)
    allow(Google::Apis::CloudresourcemanagerV3::CloudResourceManagerService).to receive(:new).and_return(crm_client)
    allow(crm_client).to receive(:authorization=)
    allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(nil)
    stub_fetch_all_via_list(crm_client)
  end

  describe ".assemble" do
    it "creates a GcpVpc and returns its strand" do
      assemble_project = Project.create(name: "test-gcp-vpc-assemble")
      st = described_class.assemble(assemble_project.id, location.id)
      expect(st).to be_a(Strand)
      expect(st.prog).to eq("Vnet::Gcp::VpcNexus")
      vpc = st.subject
      expect(vpc).to be_a(GcpVpc)
      expect(vpc.name).to start_with("ubicloud-")
    end

    it "raises for invalid project" do
      expect { described_class.assemble(Project.generate_uuid, location.id) }
        .to raise_error("No existing project")
    end

    it "raises for invalid location" do
      expect { described_class.assemble(project.id, Location.generate_uuid) }
        .to raise_error("No existing location")
    end

    it "raises on duplicate project+location so the calling label can retry" do
      assemble_project = Project.create(name: "test-gcp-vpc-dup")
      described_class.assemble(assemble_project.id, location.id)

      expect {
        described_class.assemble(assemble_project.id, location.id)
      }.to raise_error(Sequel::ValidationFailed)
    end
  end

  describe "#start" do
    it "registers deadline and hops to create_vpc" do
      expect { nx.start }.to hop("create_vpc")
      frame = nx.strand.stack.first
      expect(frame["deadline_target"]).to eq("wait")
      expect(Time.new(frame["deadline_at"])).to be_within(5).of(Time.now + 5 * 60)
    end
  end

  describe "#create_vpc" do
    it "creates VPC and hops to wait_create_vpc" do
      expect(Config).to receive(:provider_resource_tag_value).and_return("17")
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-vpc-123")
      expect(networks_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        nr = args[:network_resource]
        expect(nr.name).to eq(vpc_name)
        expect(nr.auto_create_subnetworks).to be(false)
        expect(nr.description).to include("[Ubicloud=17]")
        op
      end

      expect { nx.create_vpc }.to hop("wait_create_vpc")
      expect(st.stack.first.dig("create_vpc", "name")).to eq("op-vpc-123")
    end

    it "handles AlreadyExistsError on INSERT and caches network_self_link" do
      expect(networks_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(networks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 11111))
      expect(Clog).to receive(:emit).with("GCP VPC created", hash_including(gcp_vpc_created: vpc_name)).and_call_original

      expect { nx.create_vpc }.to hop("create_firewall_policy")
      expect(gcp_vpc.reload.network_self_link).to include("11111")
    end

    it "does not overwrite network_self_link on AlreadyExistsError if already cached" do
      original_link = "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/99999"
      nx.gcp_vpc.update(network_self_link: original_link)

      expect(networks_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(networks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 67890))

      expect { nx.create_vpc }.to hop("create_firewall_policy")
      expect(gcp_vpc.reload.network_self_link).to eq(original_link)
    end
  end

  describe "#wait_create_vpc" do
    before do
      refresh_frame(nx, new_values: {"create_vpc" => {"name" => "op-vpc-123", "scope" => "global"}})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_create_vpc }.to nap(5)
    end

    it "stores network_self_link and hops to create_firewall_policy when operation completes" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect(networks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 12345))
      expect(Clog).to receive(:emit).with("GCP VPC created", hash_including(gcp_vpc_created: vpc_name)).and_call_original

      expect { nx.wait_create_vpc }.to hop("create_firewall_policy")
      expect(gcp_vpc.reload.network_self_link).to include("12345")
    end

    it "clears op and hops to create_vpc when LRO fails and VPC does not exist" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(networks_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.wait_create_vpc }.to hop("create_vpc")
      expect(st.stack.first["create_vpc"]).to be_nil
    end

    it "continues if LRO errors but VPC was created" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "transient error")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      # First call in op_error? recovery, second call for network_self_link
      expect(networks_client).to receive(:get).twice
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 12345))

      expect { nx.wait_create_vpc }.to hop("create_firewall_policy")
    end
  end

  describe "#create_firewall_policy" do
    it "creates firewall policy and hops to wait_firewall_policy_created" do
      expect(Config).to receive(:provider_resource_tag_value).and_return("91")
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-policy")
      expect(nfp_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:firewall_policy_resource].name).to eq(vpc_name)
        expect(args[:firewall_policy_resource].description).to include("[Ubicloud=91]")
        op
      end

      expect { nx.create_firewall_policy }.to hop("wait_firewall_policy_created")
      expect(st.stack.first.dig("create_fw_policy", "name")).to eq("op-policy")
    end

    it "hops to associate_firewall_policy when insert raises AlreadyExistsError (concurrent strand)" do
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(Clog).to receive(:emit).with("GCP firewall policy created", hash_including(gcp_firewall_policy_created: vpc_name)).and_call_original

      expect { nx.create_firewall_policy }.to hop("associate_firewall_policy")
    end
  end

  describe "#associate_firewall_policy" do
    let(:vpc_target) { "projects/test-gcp-project/global/networks/#{vpc_name}" }

    it "hops to create_vpc_deny_rules when our VPC is already associated" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name, attachment_target: vpc_target,
            ),
          ]),
      )
      expect(nfp_client).not_to receive(:add_association)
      expect(Clog).to receive(:emit).with("GCP firewall policy association created", hash_including(gcp_firewall_policy_association_created: "#{vpc_name}@#{vpc_name}")).and_call_original

      expect { nx.associate_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "creates association when policy has no association" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc")
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)

      expect { nx.associate_firewall_policy }.to hop("wait_firewall_policy_associated")
      expect(st.stack.first.dig("associate_fw_policy", "name")).to eq("op-assoc")
    end

    it "creates association when policy has nil associations" do
      expect(nfp_client).to receive(:get).and_return(Google::Cloud::Compute::V1::FirewallPolicy.new)
      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc-nil")
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)

      expect { nx.associate_firewall_policy }.to hop("wait_firewall_policy_associated")
    end

    it "verifies association and proceeds when add_association raises AlreadyExistsError and our VPC is associated" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name, attachment_target: vpc_target,
            ),
          ]),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::AlreadyExistsError.new("association exists"))
      expect(Clog).to receive(:emit).with("GCP firewall policy association created", hash_including(gcp_firewall_policy_association_created: "#{vpc_name}@#{vpc_name}")).and_call_original

      expect { nx.associate_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "naps when add_association raises AlreadyExistsError but our VPC is not associated" do
      other_target = "projects/test-gcp-project/global/networks/some-other-vpc"
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name, attachment_target: other_target,
            ),
          ]),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::AlreadyExistsError.new("association exists"))
      expect(Clog).to receive(:emit).with(/association missing/, anything).and_call_original

      expect { nx.associate_firewall_policy }.to nap(5)
    end

    it "verifies association and proceeds when add_association raises InvalidArgumentError 'already exists' and our VPC is associated" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name, attachment_target: vpc_target,
            ),
          ]),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("An association with that name already exists."))
      expect(Clog).to receive(:emit).with("GCP firewall policy association created", hash_including(gcp_firewall_policy_association_created: "#{vpc_name}@#{vpc_name}")).and_call_original

      expect { nx.associate_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "naps when add_association raises InvalidArgumentError 'already exists' but re-fetched policy has nil associations" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("An association with that name already exists."))
      expect(Clog).to receive(:emit).with(/association missing/, anything).and_call_original

      expect { nx.associate_firewall_policy }.to nap(5)
    end

    it "naps when VPC resource is not ready for association" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("The resource 'projects/test/global/networks/ubicloud-gcp-us-central1' is not ready"))

      expect { nx.associate_firewall_policy }.to nap(5)
    end

    it "re-raises InvalidArgumentError when not about association already existing or resource not ready" do
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("Invalid CIDR range"))

      expect { nx.associate_firewall_policy }.to raise_error(Google::Cloud::InvalidArgumentError, /Invalid CIDR/)
    end
  end

  describe "#verify_firewall_policy_associated_with_vpc!" do
    let(:vpc_target) { "projects/test-gcp-project/global/networks/#{vpc_name}" }

    it "hops to create_vpc_deny_rules and clears retry counter when association appears on retry" do
      policy_missing = Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name)
      policy_present = Google::Cloud::Compute::V1::FirewallPolicy.new(
        name: vpc_name,
        associations: [
          Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
            name: vpc_name, attachment_target: vpc_target,
          ),
        ],
      )
      expect(nfp_client).to receive(:get).and_return(policy_missing, policy_present)
      expect(Clog).to receive(:emit).with(/association missing/, anything).and_call_original
      expect(Clog).to receive(:emit).with("GCP firewall policy association created", hash_including(gcp_firewall_policy_association_created: "#{vpc_name}@#{vpc_name}")).and_call_original

      expect { nx.send(:verify_firewall_policy_associated_with_vpc!, vpc_target) }.to nap(5)
      expect(frame_value(nx, "verify_assoc_try")).to eq(1)

      refresh_frame(nx)
      expect { nx.send(:verify_firewall_policy_associated_with_vpc!, vpc_target) }.to hop("create_vpc_deny_rules")
      expect(frame_value(nx, "verify_assoc_try")).to eq(0)
    end

    it "raises a terminal error after VERIFY_ASSOC_MAX_TRIES unsuccessful attempts" do
      policy_missing = Google::Cloud::Compute::V1::FirewallPolicy.new(
        name: vpc_name,
        associations: [
          Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
            name: vpc_name,
            attachment_target: "projects/test-gcp-project/global/networks/some-other-vpc",
          ),
        ],
      )
      expect(nfp_client).to receive(:get)
        .and_return(policy_missing)
        .exactly(described_class::VERIFY_ASSOC_MAX_TRIES).times
      expect(Clog).to receive(:emit)
        .with("GCP firewall policy association missing after already-exists rescue", anything)
        .exactly(described_class::VERIFY_ASSOC_MAX_TRIES - 1).times
        .and_call_original

      (described_class::VERIFY_ASSOC_MAX_TRIES - 1).times do
        expect { nx.send(:verify_firewall_policy_associated_with_vpc!, vpc_target) }.to nap(5)
        refresh_frame(nx)
      end

      expect {
        nx.send(:verify_firewall_policy_associated_with_vpc!, vpc_target)
      }.to raise_error(
        RuntimeError,
        /not present after #{described_class::VERIFY_ASSOC_MAX_TRIES} attempts.*some-other-vpc/o,
      )
    end
  end

  describe "#wait_firewall_policy_created" do
    before do
      refresh_frame(nx, new_values: {"create_fw_policy" => {"name" => "op-policy-123", "scope" => "global"}})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_firewall_policy_created }.to nap(5)
    end

    it "hops to associate_firewall_policy when operation completes" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect(Clog).to receive(:emit).with("GCP firewall policy created", hash_including(gcp_firewall_policy_created: vpc_name)).and_call_original
      expect { nx.wait_firewall_policy_created }.to hop("associate_firewall_policy")
    end

    it "raises when LRO fails and policy does not exist" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "QUOTA_EXCEEDED", message: "quota exceeded")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect { nx.wait_firewall_policy_created }.to raise_error(RuntimeError, /firewall policy.*creation failed/)
    end

    it "continues if LRO errors but policy was created" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "transient error")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name))

      expect { nx.wait_firewall_policy_created }.to hop("associate_firewall_policy")
    end
  end

  describe "#wait_firewall_policy_associated" do
    before do
      refresh_frame(nx, new_values: {"associate_fw_policy" => {"name" => "op-assoc", "scope" => "global"}})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_firewall_policy_associated }.to nap(5)
    end

    it "hops to create_vpc_deny_rules when operation completes" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect(Clog).to receive(:emit).with("GCP firewall policy association created", hash_including(gcp_firewall_policy_association_created: "#{vpc_name}@#{vpc_name}")).and_call_original
      expect { nx.wait_firewall_policy_associated }.to hop("create_vpc_deny_rules")
    end

    it "logs and proceeds when LRO errors but association already exists" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      vpc_target = "projects/test-gcp-project/global/networks/#{vpc_name}"
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(
          name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name,
              attachment_target: vpc_target,
            ),
          ],
        ),
      )
      expect(Clog).to receive(:emit).with("GCP LRO error but firewall policy association exists", anything).and_call_original
      expect(Clog).to receive(:emit).with("GCP firewall policy association created", hash_including(gcp_firewall_policy_association_created: "#{vpc_name}@#{vpc_name}")).and_call_original
      expect { nx.wait_firewall_policy_associated }.to hop("create_vpc_deny_rules")
    end

    it "hops back to create_firewall_policy when LRO errors and association is missing" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name, associations: []),
      )
      expect { nx.wait_firewall_policy_associated }.to hop("create_firewall_policy")
      expect(st.reload.stack.first["associate_fw_policy"]).to be_nil
    end

    it "hops back to create_firewall_policy when LRO errors and re-fetched policy has nil associations" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get).and_return(Google::Cloud::Compute::V1::FirewallPolicy.new)
      expect { nx.wait_firewall_policy_associated }.to hop("create_firewall_policy")
    end
  end

  describe "#create_vpc_deny_rules" do
    it "creates four deny rules and hops to wait" do
      expect(nfp_client).to receive(:get_rule).exactly(4).times
        .and_raise(Google::Cloud::NotFoundError.new("not found"))

      created_rules = []
      expect(nfp_client).to receive(:add_rule).exactly(4).times do |args|
        rule = args[:firewall_policy_rule_resource]
        created_rules << {direction: rule.direction, action: rule.action, priority: rule.priority}
        instance_double(Gapic::GenericLRO::Operation, name: "op-rule")
      end

      expect { nx.create_vpc_deny_rules }.to hop("wait")

      expect(created_rules).to all(include(action: "deny"))
      priorities = created_rules.map { it[:priority] }
      expect(priorities).to contain_exactly(65534, 65533, 65532, 65531)
    end

    it "skips creation when rules already exist and match" do
      all_proto = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")

      expect(nfp_client).to receive(:get_rule).exactly(4).times do |args|
        prio = args[:priority]
        case prio
        when 65534
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "INGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              src_ip_ranges: described_class::RFC1918_RANGES,
              layer4_configs: [all_proto],
            ), target_secure_tags: [],
          )
        when 65533
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "EGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              dest_ip_ranges: described_class::RFC1918_RANGES,
              layer4_configs: [all_proto],
            ), target_secure_tags: [],
          )
        when 65532
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "INGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              src_ip_ranges: described_class::GCE_INTERNAL_IPV6_RANGES,
              layer4_configs: [all_proto],
            ), target_secure_tags: [],
          )
        when 65531
          Google::Cloud::Compute::V1::FirewallPolicyRule.new(
            direction: "EGRESS", action: "deny",
            match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
              dest_ip_ranges: described_class::GCE_INTERNAL_IPV6_RANGES,
              layer4_configs: [all_proto],
            ), target_secure_tags: [],
          )
        end
      end

      expect(nfp_client).not_to receive(:add_rule)
      expect { nx.create_vpc_deny_rules }.to hop("wait")
    end

    it "overwrites mismatched rule and logs collision" do
      # First rule has wrong direction
      wrong_rule = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "allow",
        match: Google::Cloud::Compute::V1::FirewallPolicyRuleMatcher.new(
          src_ip_ranges: ["10.0.0.0/8"],
        ), target_secure_tags: [],
      )
      expect(nfp_client).to receive(:get_rule).exactly(4).times.and_return(wrong_rule)

      expect(nfp_client).to receive(:patch_rule).exactly(4).times
        .and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-rule"))
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, overwriting rule", anything).exactly(4).times.and_call_original

      expect { nx.create_vpc_deny_rules }.to hop("wait")
    end

    it "handles AlreadyExistsError on concurrent rule creation" do
      expect(nfp_client).to receive(:get_rule).exactly(4).times
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:add_rule).exactly(4).times
        .and_raise(Google::Cloud::AlreadyExistsError.new("exists"))

      expect { nx.create_vpc_deny_rules }.to hop("wait")
    end

    it "creates rule with custom layer4_configs and target_secure_tags" do
      expect(nfp_client).to receive(:get_rule)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(nfp_client).to receive(:add_rule) do |args|
        rule = args[:firewall_policy_rule_resource]
        expect(rule.match.layer4_configs.first.ip_protocol).to eq("tcp")
        expect(rule.match.layer4_configs.first.ports).to eq(["443"])
        expect(rule.target_secure_tags.first.name).to eq("tagValues/123")
      end

      nx.send(:ensure_firewall_policy_rule,
        priority: 1000,
        direction: "INGRESS",
        action: "allow",
        src_ip_ranges: ["10.0.0.0/8"],
        layer4_configs: [{ip_protocol: "tcp", ports: ["443"]}],
        target_secure_tags: ["tagValues/123"])
    end
  end

  describe "#wait" do
    it "naps for a long time" do
      expect { nx.wait }.to nap(60 * 60 * 24 * 365)
    end

    it "hops to destroy when destroy semaphore is set" do
      st
      gcp_vpc.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to update_firewall_rules when update_firewall_rules semaphore is set" do
      st
      gcp_vpc.incr_update_firewall_rules
      expect { nx.wait }.to hop("update_firewall_rules")
    end
  end

  describe "#update_firewall_rules" do
    it "pushes VpcUpdateFirewallRules and decrements the semaphore" do
      st
      gcp_vpc.incr_update_firewall_rules
      expect { nx.update_firewall_rules }.to hop("update_firewall_rules", "Vnet::Gcp::VpcUpdateFirewallRules")
      expect(Semaphore.where(strand_id: gcp_vpc.id, name: "update_firewall_rules").count).to eq(0)
    end

    it "hops back to wait when the child prog pops with the expected message" do
      st.update(retval: Sequel.pg_jsonb({"msg" => "firewall rules updated"}))
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "registers deadline and hops to enumerate_destroy_state when no subnets remain" do
      expect { nx.destroy }.to hop("enumerate_destroy_state")
      expect(Time.parse(nx.strand.stack.first["deadline_at"])).to be_within(5).of(Time.now + 5 * 60)
      expect(nx.strand.stack.first["deadline_target"]).to eq("destroy")
    end

    it "naps when subnets still exist" do
      ps = PrivateSubnet.create(
        name: "ps", location_id: location.id, project_id: project.id,
        net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "waiting",
      )
      DB[:private_subnet_gcp_vpc].insert(private_subnet_id: ps.id, gcp_vpc_id: gcp_vpc.id)

      expect { nx.destroy }.to nap(10)
    end
  end

  describe "#enumerate_destroy_state" do
    let(:self_link) { "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555" }

    before { nx.gcp_vpc.update(network_self_link: self_link) }

    def make_tag_key(name, short_name, purpose: "GCE_FIREWALL", purpose_data: {"network" => self_link})
      Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name:, short_name:, purpose:, purpose_data:,
      )
    end

    it "populates pending_tag_key_names with matching tag keys and hops to remove_policy_associations when policy has associations" do
      matching = make_tag_key("tagKeys/999", "ubicloud-fw-match")
      wrong_prefix = make_tag_key("tagKeys/111", "other-tag")
      wrong_purpose = make_tag_key("tagKeys/222", "ubicloud-fw-badpurp", purpose: "OTHER")
      wrong_network = make_tag_key("tagKeys/333", "ubicloud-fw-othernet",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/99999"})
      nil_purpose_data = make_tag_key("tagKeys/444", "ubicloud-fw-nilpd", purpose_data: nil)

      expect(crm_client).to receive(:list_tag_keys).with(parent: "projects/test-gcp-project", page_token: nil).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(
          tag_keys: [matching, wrong_prefix, wrong_purpose, wrong_network, nil_purpose_data],
        ),
      )

      vpc_target = "projects/test-gcp-project/global/networks/#{vpc_name}"
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: "assoc-1", attachment_target: vpc_target),
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: "assoc-2", attachment_target: vpc_target),
          ],
        ),
      )

      expect { nx.enumerate_destroy_state }.to hop("remove_policy_associations")
      expect(st.stack.first["pending_tag_key_names"]).to eq(["tagKeys/999"])
      expect(st.stack.first["pending_assoc_names"]).to eq(["assoc-1", "assoc-2"])
      expect(st.stack.first["pending_tag_value_names"]).to eq([])
    end

    it "hops to delete_firewall_policy_op when policy exists but has no associations" do
      expect(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(associations: []),
      )

      expect { nx.enumerate_destroy_state }.to hop("delete_firewall_policy_op")
      expect(st.stack.first["pending_assoc_names"]).to eq([])
      expect(st.stack.first["pending_tag_key_names"]).to eq([])
    end

    it "hops to delete_firewall_tag_values_start when policy is already gone" do
      expect(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("gone"))

      expect { nx.enumerate_destroy_state }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["pending_assoc_names"]).to eq([])
    end

    it "handles nil tag_keys list response" do
      expect(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new,
      )
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("gone"))

      expect { nx.enumerate_destroy_state }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["pending_tag_key_names"]).to eq([])
    end

    it "skips tag list entirely when network_self_link is nil" do
      nx.gcp_vpc.update(network_self_link: nil)
      expect(crm_client).not_to receive(:list_tag_keys)
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("gone"))

      expect { nx.enumerate_destroy_state }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["pending_tag_key_names"]).to eq([])
    end

    it "paginates list_tag_keys and collects matching tag keys from every page" do
      page1_match = make_tag_key("tagKeys/page1-match", "ubicloud-fw-page1")
      page1_skip = make_tag_key("tagKeys/page1-skip", "other-tag")
      page2_match = make_tag_key("tagKeys/page2-match", "ubicloud-fw-page2")

      page1 = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(
        tag_keys: [page1_match, page1_skip], next_page_token: "destroy-tok",
      )
      page2 = Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(
        tag_keys: [page2_match],
      )
      expect(crm_client).to receive(:list_tag_keys)
        .with(parent: "projects/test-gcp-project", page_token: nil).ordered.and_return(page1)
      expect(crm_client).to receive(:list_tag_keys)
        .with(parent: "projects/test-gcp-project", page_token: "destroy-tok").ordered.and_return(page2)
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("gone"))

      expect { nx.enumerate_destroy_state }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["pending_tag_key_names"])
        .to contain_exactly("tagKeys/page1-match", "tagKeys/page2-match")
    end
  end

  describe "#remove_policy_associations" do
    before do
      refresh_frame(nx, new_values: {"pending_assoc_names" => ["assoc-a", "assoc-b"]})
    end

    it "issues remove_association, saves LRO, and hops to wait" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-remove")
      expect(nfp_client).to receive(:remove_association).with(
        project: "test-gcp-project", firewall_policy: vpc_name, name: "assoc-a",
      ).and_return(op)

      expect { nx.remove_policy_associations }.to hop("wait_policy_association_removed")
      expect(st.stack.first.dig("remove_assoc", "name")).to eq("op-remove")
      expect(st.stack.first["remove_assoc_resource_name"]).to eq("assoc-a")
      expect(st.stack.first["pending_assoc_names"]).to eq(["assoc-b"])
    end

    it "skips wait and loops when remove_association raises NotFoundError with more pending" do
      expect(nfp_client).to receive(:remove_association)
        .and_raise(Google::Cloud::NotFoundError.new("gone"))
      expect(Clog).to receive(:emit).with("GCP firewall policy association already gone; proceeding", anything).and_call_original

      expect { nx.remove_policy_associations }.to hop("remove_policy_associations")
      expect(st.stack.first["pending_assoc_names"]).to eq(["assoc-b"])
    end

    it "hops to delete_firewall_policy_op when NotFoundError drains the pending list" do
      refresh_frame(nx, new_values: {"pending_assoc_names" => ["only"]})
      expect(nfp_client).to receive(:remove_association)
        .and_raise(Google::Cloud::NotFoundError.new("gone"))
      expect(Clog).to receive(:emit).with("GCP firewall policy association already gone; proceeding", anything).and_call_original

      expect { nx.remove_policy_associations }.to hop("delete_firewall_policy_op")
      expect(st.stack.first["pending_assoc_names"]).to eq([])
    end

    it "propagates unexpected errors from remove_association" do
      expect(nfp_client).to receive(:remove_association)
        .and_raise(Google::Cloud::InternalError.new("boom"))

      expect { nx.remove_policy_associations }.to raise_error(Google::Cloud::InternalError)
    end
  end

  describe "#wait_policy_association_removed" do
    before do
      refresh_frame(nx, new_values: {
        "remove_assoc" => {"name" => "op-remove", "scope" => "global"},
        "remove_assoc_resource_name" => "assoc-a",
        "pending_assoc_names" => ["assoc-b"],
      })
    end

    it "naps when LRO is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_policy_association_removed }.to nap(5)
    end

    it "hops back to remove_policy_associations when pending drains to more work" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect { nx.wait_policy_association_removed }.to hop("remove_policy_associations")
      expect(st.stack.first["remove_assoc_resource_name"]).to be_nil
    end

    it "hops to delete_firewall_policy_op when pending is empty" do
      refresh_frame(nx, new_values: {"pending_assoc_names" => []})
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect { nx.wait_policy_association_removed }.to hop("delete_firewall_policy_op")
    end

    it "logs and proceeds when LRO errors but association is gone from policy" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "TRANSIENT", message: "transient")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(associations: []),
      )
      expect(Clog).to receive(:emit).with("GCP firewall policy association already gone despite LRO error; proceeding", anything).and_call_original

      expect { nx.wait_policy_association_removed }.to hop("remove_policy_associations")
    end

    it "raises when LRO errors and association still present" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "X", message: "stuck")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(
          associations: [Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: "assoc-a")],
        ),
      )

      expect { nx.wait_policy_association_removed }.to raise_error(RuntimeError, /assoc-a.*still present/)
    end

    it "proceeds when LRO errors and policy itself is gone" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "X", message: "policy vanished")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("gone"))
      expect(Clog).to receive(:emit).with("GCP firewall policy already gone despite LRO error; proceeding", anything).and_call_original

      expect { nx.wait_policy_association_removed }.to hop("remove_policy_associations")
    end
  end

  describe "#delete_firewall_policy_op" do
    it "issues delete, saves LRO slot, and hops to wait" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-del-policy")
      expect(nfp_client).to receive(:delete).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_return(op)

      expect { nx.delete_firewall_policy_op }.to hop("wait_firewall_policy_deleted")
      expect(st.stack.first.dig("delete_fw_policy", "name")).to eq("op-del-policy")
    end

    it "skips LRO tracking and hops to tag cleanup when delete raises NotFoundError" do
      expect(nfp_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("gone"))
      expect(Clog).to receive(:emit).with("GCP firewall policy already gone; proceeding", anything).and_call_original

      expect { nx.delete_firewall_policy_op }.to hop("delete_firewall_tag_values_start")
    end
  end

  describe "#wait_firewall_policy_deleted" do
    before do
      refresh_frame(nx, new_values: {"delete_fw_policy" => {"name" => "op-del-policy", "scope" => "global"}})
    end

    it "naps when LRO is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_firewall_policy_deleted }.to nap(5)
    end

    it "hops to tag cleanup when LRO completes" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect { nx.wait_firewall_policy_deleted }.to hop("delete_firewall_tag_values_start")
    end

    it "logs and proceeds when LRO errors but policy is gone" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "T", message: "transient")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("gone"))
      expect(Clog).to receive(:emit).with("GCP firewall policy already gone despite LRO error; proceeding", anything).and_call_original

      expect { nx.wait_firewall_policy_deleted }.to hop("delete_firewall_tag_values_start")
    end

    it "raises when LRO errors and policy still present with no associations" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "X", message: "stuck")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(nfp_client).to receive(:get).and_return(Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name))

      expect { nx.wait_firewall_policy_deleted }.to raise_error(RuntimeError, /firewall policy.*still present.*no pending associations/)
    end

    it "hops to enumerate_destroy_state when LRO errors and policy has associations" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "X", message: "stuck")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      policy_with_assoc = Google::Cloud::Compute::V1::FirewallPolicy.new(
        name: vpc_name,
        associations: [
          Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: "assoc-new"),
        ],
      )
      expect(nfp_client).to receive(:get).and_return(policy_with_assoc)
      expect(Clog).to receive(:emit).with("GCP firewall policy still has associations after LRO; re-enumerating", anything).and_call_original

      expect { nx.wait_firewall_policy_deleted }.to hop("enumerate_destroy_state")
    end
  end

  describe "#delete_firewall_tag_values_start" do
    it "hops to delete_vpc_network_op when no tag keys pending" do
      refresh_frame(nx, new_values: {"pending_tag_key_names" => []})
      expect { nx.delete_firewall_tag_values_start }.to hop("delete_vpc_network_op")
    end

    it "populates pending_tag_value_names and hops to delete_firewall_tag_values" do
      refresh_frame(nx, new_values: {"pending_tag_key_names" => ["tagKeys/999"]})
      expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/999", page_token: nil).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
          tag_values: [
            Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/1"),
            Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/2"),
          ],
        ),
      )

      expect { nx.delete_firewall_tag_values_start }.to hop("delete_firewall_tag_values")
      expect(st.stack.first["pending_tag_value_names"]).to eq(["tagValues/1", "tagValues/2"])
    end

    it "handles nil tag_values (empty pending list)" do
      refresh_frame(nx, new_values: {"pending_tag_key_names" => ["tagKeys/999"]})
      expect(crm_client).to receive(:list_tag_values).with(parent: "tagKeys/999", page_token: nil).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new,
      )

      expect { nx.delete_firewall_tag_values_start }.to hop("delete_firewall_tag_values")
      expect(st.stack.first["pending_tag_value_names"]).to eq([])
    end

    it "paginates list_tag_values and collects every tag value across pages" do
      refresh_frame(nx, new_values: {"pending_tag_key_names" => ["tagKeys/999"]})
      page1 = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
        tag_values: [Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/p1")],
        next_page_token: "tv-tok",
      )
      page2 = Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(
        tag_values: [
          Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/p2-a"),
          Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/p2-b"),
        ],
      )
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: "tagKeys/999", page_token: nil).ordered.and_return(page1)
      expect(crm_client).to receive(:list_tag_values)
        .with(parent: "tagKeys/999", page_token: "tv-tok").ordered.and_return(page2)

      expect { nx.delete_firewall_tag_values_start }.to hop("delete_firewall_tag_values")
      expect(st.stack.first["pending_tag_value_names"]).to eq(["tagValues/p1", "tagValues/p2-a", "tagValues/p2-b"])
    end
  end

  describe "#delete_firewall_tag_values" do
    it "hops to delete_firewall_tag_key_current when no tag values pending" do
      refresh_frame(nx, new_values: {"pending_tag_value_names" => []})
      expect { nx.delete_firewall_tag_values }.to hop("delete_firewall_tag_key_current")
    end

    it "issues delete_tag_value, stashes op name, drops head, and hops to wait" do
      refresh_frame(nx, new_values: {"pending_tag_value_names" => ["tagValues/1", "tagValues/2"]})
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(name: "operations/tv-del", done: false)
      expect(crm_client).to receive(:delete_tag_value).with("tagValues/1").and_return(op)

      expect { nx.delete_firewall_tag_values }.to hop("wait_firewall_tag_value_deleted")
      expect(st.stack.first["delete_tv"]).to eq({"op_name" => "operations/tv-del", "name" => "tagValues/1"})
      expect(st.stack.first["pending_tag_value_names"]).to eq(["tagValues/2"])
    end

    it "drops head and loops when delete_tag_value raises 404" do
      refresh_frame(nx, new_values: {"pending_tag_value_names" => ["tagValues/1", "tagValues/2"]})
      expect(crm_client).to receive(:delete_tag_value).with("tagValues/1")
        .and_raise(Google::Apis::ClientError.new("gone", status_code: 404))
      expect(Clog).to receive(:emit).with("GCP tag value already gone; proceeding", anything).and_call_original

      expect { nx.delete_firewall_tag_values }.to hop("delete_firewall_tag_values")
      expect(st.stack.first["pending_tag_value_names"]).to eq(["tagValues/2"])
    end

    it "propagates non-404 ClientError from delete_tag_value" do
      refresh_frame(nx, new_values: {"pending_tag_value_names" => ["tagValues/1"]})
      expect(crm_client).to receive(:delete_tag_value)
        .and_raise(Google::Apis::ClientError.new("denied", status_code: 403))

      expect { nx.delete_firewall_tag_values }.to raise_error(Google::Apis::ClientError, /denied/)
    end
  end

  describe "#wait_firewall_tag_value_deleted" do
    before do
      refresh_frame(nx, new_values: {"delete_tv" => {"op_name" => "operations/tv-del", "name" => "tagValues/1"}})
    end

    it "naps when operation is not done" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: false)
      expect(crm_client).to receive(:get_operation).with("operations/tv-del").and_return(op)
      expect { nx.wait_firewall_tag_value_deleted }.to nap(5)
    end

    it "clears frame and hops back on success" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
      expect(crm_client).to receive(:get_operation).and_return(op)

      expect { nx.wait_firewall_tag_value_deleted }.to hop("delete_firewall_tag_values")
      expect(st.stack.first["delete_tv"]).to be_nil
    end

    it "proceeds on LRO error when tag value is actually gone" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true,
        error: Google::Apis::CloudresourcemanagerV3::Status.new(code: 2, message: "boom"),
      )
      expect(crm_client).to receive(:get_operation).and_return(op)
      expect(crm_client).to receive(:get_tag_value).with("tagValues/1")
        .and_raise(Google::Apis::ClientError.new("gone", status_code: 404))
      expect(Clog).to receive(:emit).with("GCP tag value already gone despite LRO error; proceeding", anything).and_call_original

      expect { nx.wait_firewall_tag_value_deleted }.to hop("delete_firewall_tag_values")
    end

    it "raises on LRO error when tag value still present" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true,
        error: Google::Apis::CloudresourcemanagerV3::Status.new(code: 9, message: "still attached"),
      )
      expect(crm_client).to receive(:get_operation).and_return(op)
      expect(crm_client).to receive(:get_tag_value).with("tagValues/1")
        .and_return(Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/1"))

      expect { nx.wait_firewall_tag_value_deleted }.to raise_error(RuntimeError, /tagValues\/1.*still present.*still attached/)
    end

    it "propagates non-404 ClientError during recovery GET" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true,
        error: Google::Apis::CloudresourcemanagerV3::Status.new(code: 13, message: "boom"),
      )
      expect(crm_client).to receive(:get_operation).and_return(op)
      expect(crm_client).to receive(:get_tag_value)
        .and_raise(Google::Apis::ClientError.new("denied", status_code: 403))

      expect { nx.wait_firewall_tag_value_deleted }.to raise_error(Google::Apis::ClientError, /denied/)
    end
  end

  describe "#delete_firewall_tag_key_current" do
    it "issues delete_tag_key, stashes op name, preserves pending head, and hops to wait" do
      refresh_frame(nx, new_values: {"pending_tag_key_names" => ["tagKeys/999", "tagKeys/888"]})
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(name: "operations/tk-del", done: false)
      expect(crm_client).to receive(:delete_tag_key).with("tagKeys/999").and_return(op)

      expect { nx.delete_firewall_tag_key_current }.to hop("wait_firewall_tag_key_deleted")
      expect(st.stack.first["delete_tk"]).to eq({"op_name" => "operations/tk-del", "name" => "tagKeys/999"})
      expect(st.stack.first["pending_tag_key_names"]).to eq(["tagKeys/999", "tagKeys/888"])
    end

    it "drops head and loops through tag_values_start when delete_tag_key raises 404" do
      refresh_frame(nx, new_values: {"pending_tag_key_names" => ["tagKeys/999", "tagKeys/888"]})
      expect(crm_client).to receive(:delete_tag_key).with("tagKeys/999")
        .and_raise(Google::Apis::ClientError.new("gone", status_code: 404))
      expect(Clog).to receive(:emit).with("GCP tag key already gone; proceeding", anything).and_call_original

      expect { nx.delete_firewall_tag_key_current }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["pending_tag_key_names"]).to eq(["tagKeys/888"])
    end

    it "propagates non-404 ClientError" do
      refresh_frame(nx, new_values: {"pending_tag_key_names" => ["tagKeys/999"]})
      expect(crm_client).to receive(:delete_tag_key)
        .and_raise(Google::Apis::ClientError.new("denied", status_code: 403))

      expect { nx.delete_firewall_tag_key_current }.to raise_error(Google::Apis::ClientError, /denied/)
    end
  end

  describe "#wait_firewall_tag_key_deleted" do
    before do
      refresh_frame(nx, new_values: {
        "delete_tk" => {"op_name" => "operations/tk-del", "name" => "tagKeys/999"},
        "pending_tag_key_names" => ["tagKeys/999", "tagKeys/next"],
      })
    end

    it "naps when operation is not done" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: false)
      expect(crm_client).to receive(:get_operation).with("operations/tk-del").and_return(op)
      expect { nx.wait_firewall_tag_key_deleted }.to nap(5)
    end

    it "pops pending head, clears frame, and hops to tag_values_start on success" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(done: true)
      expect(crm_client).to receive(:get_operation).and_return(op)

      expect { nx.wait_firewall_tag_key_deleted }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["delete_tk"]).to be_nil
      expect(st.stack.first["pending_tag_key_names"]).to eq(["tagKeys/next"])
    end

    it "pops pending head and proceeds on LRO error when tag key is gone" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true,
        error: Google::Apis::CloudresourcemanagerV3::Status.new(code: 2, message: "boom"),
      )
      expect(crm_client).to receive(:get_operation).and_return(op)
      expect(crm_client).to receive(:get_tag_key).with("tagKeys/999")
        .and_raise(Google::Apis::ClientError.new("gone", status_code: 404))
      expect(Clog).to receive(:emit).with("GCP tag key already gone despite LRO error; proceeding", anything).and_call_original

      expect { nx.wait_firewall_tag_key_deleted }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["pending_tag_key_names"]).to eq(["tagKeys/next"])
      expect(st.stack.first["delete_tk"]).to be_nil
    end

    it "hops back to delete_firewall_tag_values_start on FAILED_PRECONDITION with key still present" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true,
        error: Google::Apis::CloudresourcemanagerV3::Status.new(code: 9, message: "children exist"),
      )
      expect(crm_client).to receive(:get_operation).and_return(op)
      expect(crm_client).to receive(:get_tag_key).with("tagKeys/999")
        .and_return(Google::Apis::CloudresourcemanagerV3::TagKey.new(name: "tagKeys/999"))
      expect(Clog).to receive(:emit).with("GCP tag key has new children after LRO; re-draining values", anything).and_call_original

      expect { nx.wait_firewall_tag_key_deleted }.to hop("delete_firewall_tag_values_start")
      expect(st.stack.first["pending_tag_key_names"]).to eq(["tagKeys/999", "tagKeys/next"])
      expect(st.stack.first["delete_tk"]).to be_nil
    end

    it "raises on non-precondition error with tag key still present" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true,
        error: Google::Apis::CloudresourcemanagerV3::Status.new(code: 13, message: "internal"),
      )
      expect(crm_client).to receive(:get_operation).and_return(op)
      expect(crm_client).to receive(:get_tag_key).with("tagKeys/999")
        .and_return(Google::Apis::CloudresourcemanagerV3::TagKey.new(name: "tagKeys/999"))

      expect { nx.wait_firewall_tag_key_deleted }.to raise_error(RuntimeError, /tag key.*still present/)
    end

    it "propagates non-404 ClientError during recovery GET" do
      op = Google::Apis::CloudresourcemanagerV3::Operation.new(
        done: true,
        error: Google::Apis::CloudresourcemanagerV3::Status.new(code: 13, message: "boom"),
      )
      expect(crm_client).to receive(:get_operation).and_return(op)
      expect(crm_client).to receive(:get_tag_key)
        .and_raise(Google::Apis::ClientError.new("denied", status_code: 403))

      expect { nx.wait_firewall_tag_key_deleted }.to raise_error(Google::Apis::ClientError, /denied/)
    end
  end

  describe "#delete_vpc_network_op" do
    it "issues delete, saves LRO slot, and hops to wait" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-del-vpc")
      expect(networks_client).to receive(:delete).with(
        project: "test-gcp-project", network: vpc_name,
      ).and_return(op)

      expect { nx.delete_vpc_network_op }.to hop("wait_vpc_network_deleted")
      expect(st.stack.first.dig("delete_vpc", "name")).to eq("op-del-vpc")
    end

    it "skips LRO and hops to finalize_destroy when delete raises NotFoundError" do
      expect(networks_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("gone"))
      expect(Clog).to receive(:emit).with("GCP VPC network already gone; proceeding", anything).and_call_original

      expect { nx.delete_vpc_network_op }.to hop("finalize_destroy")
    end
  end

  describe "#wait_vpc_network_deleted" do
    before do
      refresh_frame(nx, new_values: {"delete_vpc" => {"name" => "op-del-vpc", "scope" => "global"}})
    end

    it "naps when LRO is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_vpc_network_deleted }.to nap(5)
    end

    it "hops to finalize_destroy when LRO completes" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect { nx.wait_vpc_network_deleted }.to hop("finalize_destroy")
    end

    it "logs and proceeds when LRO errors but network is gone" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "T", message: "transient")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(networks_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("gone"))
      expect(Clog).to receive(:emit).with("GCP VPC network already gone despite LRO error; proceeding", anything).and_call_original

      expect { nx.wait_vpc_network_deleted }.to hop("finalize_destroy")
    end

    it "raises when LRO errors and network is still present" do
      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "X", message: "stuck")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(global_ops_client).to receive(:get).and_return(op)
      expect(networks_client).to receive(:get).and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name))

      expect { nx.wait_vpc_network_deleted }.to raise_error(RuntimeError, /VPC network.*still present/)
    end
  end

  describe "#finalize_destroy" do
    it "destroys GcpVpc row and pops" do
      vpc_id = gcp_vpc.id
      expect { nx.finalize_destroy }.to exit({"msg" => "vpc destroyed"})
      expect(GcpVpc[vpc_id]).to be_nil
    end
  end

  describe "#normalize_layer4_configs" do
    it "handles configs with nil ports" do
      config = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      result = nx.send(:normalize_layer4_configs, [config])
      expect(result).to eq([["all", []]])
    end
  end

  describe "#firewall_policy_rule_matches_desired?" do
    it "returns false when existing.match is nil" do
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
  end
end
