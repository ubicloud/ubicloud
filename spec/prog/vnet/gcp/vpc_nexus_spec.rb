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
      expect { described_class.assemble(SecureRandom.uuid, location.id) }
        .to raise_error("No existing project")
    end

    it "raises for invalid location" do
      expect { described_class.assemble(project.id, SecureRandom.uuid) }
        .to raise_error("No existing location")
    end

    it "returns existing VPC's strand on duplicate project+location" do
      assemble_project = Project.create(name: "test-gcp-vpc-dup")
      described_class.assemble(assemble_project.id, location.id)
      existing_vpc = GcpVpc.first(project_id: assemble_project.id, location_id: location.id)

      result = described_class.assemble(assemble_project.id, location.id)
      expect(result).to be_a(Strand)
      expect(result.subject.id).to eq(existing_vpc.id)
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
    it "skips creation and caches network_self_link if VPC already exists" do
      expect(networks_client).to receive(:get).with(
        project: "test-gcp-project",
        network: vpc_name,
      ).and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 67890))

      expect { nx.create_vpc }.to hop("create_firewall_policy")
      expect(gcp_vpc.reload.network_self_link).to include("67890")
    end

    it "does not overwrite network_self_link if already cached" do
      original_link = "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/99999"
      nx.gcp_vpc.update(network_self_link: original_link)

      expect(networks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 67890))

      expect { nx.create_vpc }.to hop("create_firewall_policy")
      expect(gcp_vpc.reload.network_self_link).to eq(original_link)
    end

    it "creates VPC and hops to wait_create_vpc" do
      expect(networks_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-vpc-123")
      expect(networks_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        nr = args[:network_resource]
        expect(nr.name).to eq(vpc_name)
        expect(nr.auto_create_subnetworks).to be(false)
        expect(nr.description).not_to include("e2e_run_id=")
        op
      end

      expect { nx.create_vpc }.to hop("wait_create_vpc")
      expect(st.stack.first["create_vpc_name"]).to eq("op-vpc-123")
    end

    it "stamps the VPC description with e2e_run_id when E2E_RUN_ID is set" do
      stub_const("ENV", ENV.to_h.merge("E2E_RUN_ID" => "17"))
      expect(networks_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-vpc-e2e")
      expect(networks_client).to receive(:insert) do |args|
        expect(args[:network_resource].description).to include("[e2e_run_id=17]")
        op
      end

      expect { nx.create_vpc }.to hop("wait_create_vpc")
    end

    it "handles AlreadyExistsError on INSERT and caches network_self_link" do
      expect(networks_client).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(networks_client).to receive(:get)
        .and_return(Google::Cloud::Compute::V1::Network.new(name: vpc_name, id: 11111))

      expect { nx.create_vpc }.to hop("create_firewall_policy")
      expect(gcp_vpc.reload.network_self_link).to include("11111")
    end
  end

  describe "#wait_create_vpc" do
    before do
      refresh_frame(nx, new_values: {"create_vpc_name" => "op-vpc-123", "create_vpc_scope" => "global"})
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
      expect(st.stack.first["create_vpc_name"]).to be_nil
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
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-policy")
      expect(nfp_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:firewall_policy_resource].name).to eq(vpc_name)
        expect(args[:firewall_policy_resource].description).not_to include("e2e_run_id=")
        op
      end

      expect { nx.create_firewall_policy }.to hop("wait_firewall_policy_created")
      expect(st.stack.first["create_fw_policy_name"]).to eq("op-policy")
    end

    it "stamps the firewall policy description with e2e_run_id when E2E_RUN_ID is set" do
      stub_const("ENV", ENV.to_h.merge("E2E_RUN_ID" => "91"))
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-policy-e2e")
      expect(nfp_client).to receive(:insert) do |args|
        expect(args[:firewall_policy_resource].description).to include("[e2e_run_id=91]")
        op
      end

      expect { nx.create_firewall_policy }.to hop("wait_firewall_policy_created")
    end

    it "skips creation but ensures association when firewall policy already exists and is associated" do
      vpc_target = "projects/test-gcp-project/global/networks/#{vpc_name}"
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name,
          associations: [
            Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(
              name: vpc_name, attachment_target: vpc_target,
            ),
          ]),
      )
      expect(nfp_client).not_to receive(:add_association)

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "creates association when policy exists but has no association" do
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )

      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc")
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)

      expect { nx.create_firewall_policy }.to hop("wait_firewall_policy_associated")
      expect(st.stack.first["associate_fw_policy_name"]).to eq("op-assoc")
    end

    it "verifies association and proceeds when add_association raises AlreadyExistsError and our VPC is associated" do
      vpc_target = "projects/test-gcp-project/global/networks/#{vpc_name}"
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
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

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "naps when add_association raises AlreadyExistsError but our VPC is not associated" do
      other_target = "projects/test-gcp-project/global/networks/some-other-vpc"
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
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
      expect(Clog).to receive(:emit).with(/association missing/, anything)

      expect { nx.create_firewall_policy }.to nap(5)
    end

    it "verifies association and proceeds when add_association raises InvalidArgumentError 'already exists' and our VPC is associated" do
      vpc_target = "projects/test-gcp-project/global/networks/#{vpc_name}"
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
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

      expect { nx.create_firewall_policy }.to hop("create_vpc_deny_rules")
    end

    it "naps when add_association raises InvalidArgumentError 'already exists' but re-fetched policy has nil associations" do
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("An association with that name already exists."))
      expect(Clog).to receive(:emit).with(/association missing/, anything)

      expect { nx.create_firewall_policy }.to nap(5)
    end

    it "naps when VPC resource is not ready for association" do
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("The resource 'projects/test/global/networks/ubicloud-gcp-us-central1' is not ready"))

      expect { nx.create_firewall_policy }.to nap(5)
    end

    it "re-raises InvalidArgumentError when not about association already existing or resource not ready" do
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("already exists"))
      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      expect(nfp_client).to receive(:add_association)
        .and_raise(Google::Cloud::InvalidArgumentError.new("Invalid CIDR range"))

      expect { nx.create_firewall_policy }.to raise_error(Google::Cloud::InvalidArgumentError, /Invalid CIDR/)
    end

    it "re-fetches and adds association after AlreadyExistsError from policy insert" do
      expect(nfp_client).to receive(:insert)
        .and_raise(Google::Cloud::AlreadyExistsError.new("policy already exists"))

      expect(nfp_client).to receive(:get).and_return(
        Google::Cloud::Compute::V1::FirewallPolicy.new(name: vpc_name),
      )
      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc-recovery")
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)

      expect { nx.create_firewall_policy }.to hop("wait_firewall_policy_associated")
    end

    it "adds association when re-fetch after insert AlreadyExistsError returns nil associations" do
      expect(nfp_client).to receive(:insert).and_raise(Google::Cloud::AlreadyExistsError.new("exists"))

      policy_nil_assoc = Google::Cloud::Compute::V1::FirewallPolicy.new
      expect(nfp_client).to receive(:get).and_return(policy_nil_assoc)

      assoc_op = instance_double(Gapic::GenericLRO::Operation, name: "op-assoc-nil")
      expect(nfp_client).to receive(:add_association).and_return(assoc_op)

      expect { nx.create_firewall_policy }.to hop("wait_firewall_policy_associated")
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
      expect(Clog).to receive(:emit).with(/association missing/, anything)

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
      allow(Clog).to receive(:emit)

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
      refresh_frame(nx, new_values: {"create_fw_policy_name" => "op-policy-123", "create_fw_policy_scope" => "global"})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_firewall_policy_created }.to nap(5)
    end

    it "stores firewall_policy_name and hops to create_firewall_policy when operation completes" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
      expect { nx.wait_firewall_policy_created }.to hop("create_firewall_policy")
      expect(gcp_vpc.reload.firewall_policy_name).to eq(vpc_name)
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

      expect { nx.wait_firewall_policy_created }.to hop("create_firewall_policy")
    end
  end

  describe "#wait_firewall_policy_associated" do
    before do
      refresh_frame(nx, new_values: {"associate_fw_policy_name" => "op-assoc", "associate_fw_policy_scope" => "global"})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(global_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_firewall_policy_associated }.to nap(5)
    end

    it "hops to create_vpc_deny_rules when operation completes" do
      expect(global_ops_client).to receive(:get).and_return(done_op)
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
      expect(st.reload.stack.first["associate_fw_policy_name"]).to be_nil
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
      expect(Clog).to receive(:emit).with("GCP firewall priority collision, overwriting rule", anything).exactly(4).times

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

      nx.send(:ensure_policy_rule,
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
  end

  describe "#destroy" do
    it "destroys VPC when no subnets remain" do
      expect(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:delete)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
      expect(GcpVpc[gcp_vpc.id]).to be_nil
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

    it "cleans up firewall tag keys, policy, and VPC network" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      # delete_all_firewall_tag_keys
      fw_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/999", short_name: "ubicloud-fw-fwtest", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555"},
      )
      other_vpc_tag = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/777", short_name: "ubicloud-fw-other", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/99999"},
      )
      unrelated_tag = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/555", short_name: "other-tag", purpose: "GCE_FIREWALL",
      )
      tag_val = Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/888", short_name: "active")
      allow(crm_client).to receive_messages(
        list_tag_keys: Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [fw_tag_key, other_vpc_tag, unrelated_tag]),
        list_tag_values: Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [tag_val]),
      )
      expect(crm_client).to receive(:delete_tag_value).with("tagValues/888")
      expect(crm_client).to receive(:delete_tag_key).with("tagKeys/999")

      # delete_firewall_policy
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        associations: [Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: vpc_name)],
      )
      expect(nfp_client).to receive(:get).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_return(policy)
      expect(nfp_client).to receive(:remove_association)
        .and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-remove-assoc"))
      expect(nfp_client).to receive(:delete).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-delete-policy"))

      # delete_vpc_network
      expect(networks_client).to receive(:delete).with(
        project: "test-gcp-project", network: vpc_name,
      )

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
    end

    it "propagates errors from list_tag_keys during destroy" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      allow(crm_client).to receive(:list_tag_keys)
        .and_raise(Google::Apis::ClientError.new("permission denied", status_code: 403))

      expect { nx.destroy }.to raise_error(Google::Apis::ClientError, /permission denied/)
    end

    it "propagates errors from delete_tag_key during destroy" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      fw_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/999", short_name: "ubicloud-fw-fwfail", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555"},
      )
      allow(crm_client).to receive_messages(
        list_tag_keys: Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [fw_tag_key]),
        list_tag_values: Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: []),
      )
      allow(crm_client).to receive(:delete_tag_key)
        .and_raise(Google::Cloud::PermissionDeniedError.new("denied"))

      expect { nx.destroy }.to raise_error(Google::Cloud::PermissionDeniedError)
    end

    it "propagates errors from remove_association during destroy" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )

      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        associations: [
          Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: "assoc-fail"),
        ],
      )
      expect(nfp_client).to receive(:get).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_return(policy)

      expect(nfp_client).to receive(:remove_association).with(
        project: "test-gcp-project", firewall_policy: vpc_name, name: "assoc-fail",
      ).and_raise(Google::Cloud::InternalError.new("internal"))

      expect { nx.destroy }.to raise_error(Google::Cloud::InternalError)
    end

    it "handles NotFoundError on individual association removal during firewall policy cleanup" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )

      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(
        associations: [
          Google::Cloud::Compute::V1::FirewallPolicyAssociation.new(name: "assoc-gone"),
        ],
      )
      expect(nfp_client).to receive(:get).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_return(policy)

      expect(nfp_client).to receive(:remove_association).with(
        project: "test-gcp-project", firewall_policy: vpc_name, name: "assoc-gone",
      ).and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(nfp_client).to receive(:delete).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-delete-policy"))

      expect(networks_client).to receive(:delete)

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
    end

    it "propagates RuntimeError from CRM LRO during firewall tag cleanup" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      fw_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/999", short_name: "ubicloud-fw-fwghost", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555"},
      )
      tag_val = Google::Apis::CloudresourcemanagerV3::TagValue.new(name: "tagValues/888", short_name: "active")
      allow(crm_client).to receive_messages(
        list_tag_keys: Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [fw_tag_key]),
        list_tag_values: Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new(tag_values: [tag_val]),
      )
      allow(crm_client).to receive(:delete_tag_value)
        .and_raise(RuntimeError.new("CRM operation op-1 failed: Cannot delete tag value still attached to resources"))

      expect { nx.destroy }.to raise_error(RuntimeError, /Cannot delete tag value/)
    end

    it "handles policy deleted between get and delete" do
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )

      # get succeeds: policy exists at this point.
      policy = Google::Cloud::Compute::V1::FirewallPolicy.new(associations: [])
      expect(nfp_client).to receive(:get).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_return(policy)

      # delete raises NotFoundError: policy was deleted between get and delete.
      expect(nfp_client).to receive(:delete).with(
        project: "test-gcp-project", firewall_policy: vpc_name,
      ).and_raise(Google::Cloud::NotFoundError.new("not found"))

      expect(networks_client).to receive(:delete)

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
    end

    it "raises when VPC network is still in use" do
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: []),
      )
      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:delete)
        .and_raise(Google::Cloud::InvalidArgumentError.new("The resource is being used by another resource"))

      expect { nx.destroy }.to raise_error(Google::Cloud::InvalidArgumentError, /being used by/)
    end

    it "skips firewall tag keys with nil purpose_data" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      nil_purpose_data_tag = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/888", short_name: "ubicloud-fw-nilpurpose", purpose: "GCE_FIREWALL",
        purpose_data: nil,
      )
      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [nil_purpose_data_tag]),
      )
      expect(crm_client).not_to receive(:delete_tag_key)

      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:delete)

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
    end

    it "handles nil tag_keys from CRM response" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      allow(crm_client).to receive(:list_tag_keys).and_return(
        Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new,
      )

      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:delete)

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
    end

    it "handles nil tag_values from CRM response" do
      nx.gcp_vpc.update(network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555")

      fw_tag_key = Google::Apis::CloudresourcemanagerV3::TagKey.new(
        name: "tagKeys/999", short_name: "ubicloud-fw-fwnilvals", purpose: "GCE_FIREWALL",
        purpose_data: {"network" => "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/55555"},
      )
      allow(crm_client).to receive_messages(
        list_tag_keys: Google::Apis::CloudresourcemanagerV3::ListTagKeysResponse.new(tag_keys: [fw_tag_key]),
        list_tag_values: Google::Apis::CloudresourcemanagerV3::ListTagValuesResponse.new,
      )
      expect(crm_client).to receive(:delete_tag_key).with("tagKeys/999")

      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:delete)

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
    end

    it "skips tag cleanup when network_self_link is nil" do
      nx.gcp_vpc.update(network_self_link: nil)

      expect(crm_client).not_to receive(:list_tag_keys)

      allow(nfp_client).to receive(:get)
        .and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect(networks_client).to receive(:delete)

      expect { nx.destroy }.to exit({"msg" => "vpc destroyed"})
    end
  end

  describe "#normalize_layer4_configs" do
    it "handles configs with nil ports" do
      config = Google::Cloud::Compute::V1::FirewallPolicyRuleMatcherLayer4Config.new(ip_protocol: "all")
      result = nx.send(:normalize_layer4_configs, [config])
      expect(result).to eq([["all", []]])
    end
  end

  describe "#policy_rule_matches_desired?" do
    it "returns false when existing.match is nil" do
      rule_no_match = Google::Cloud::Compute::V1::FirewallPolicyRule.new(
        direction: "EGRESS", action: "deny",
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
          layer4_configs: [all_proto],
        ),
        target_secure_tags: [tag],
      )
      result = nx.send(:policy_rule_matches_desired?, rule,
        direction: "EGRESS", action: "allow",
        src_ip_ranges: nil, dest_ip_ranges: ["10.0.0.0/26"],
        layer4_configs: [all_proto],
        target_secure_tags: ["tagValues/123"])
      expect(result).to be(true)
    end
  end
end
