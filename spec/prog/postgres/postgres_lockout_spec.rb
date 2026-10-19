# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::PostgresLockout do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_timeline) { create_postgres_timeline(location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource, timeline: postgres_timeline) }
  let(:st) { postgres_server.strand }
  let(:server) { nx.postgres_server }
  let(:sshable) { server.vm.sshable }
  let(:resource) { postgres_resource }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }

  describe "#start" do
    it "uses the appropriate lockout mechanism" do
      ["pg_stop", "hba", "host_routing", "detach_nic"].each do |mechanism|
        refresh_frame(nx, new_frame: {"mechanism" => mechanism})
        expect(nx).to receive("lockout_with_#{mechanism}").and_return(true)
        expect(Clog).to receive(:emit).with("Fenced unresponsive primary", {fenced_unresponsive_primary: {server_ubid: server.ubid, mechanism:}})
        expect { nx.start }.to exit({"msg" => "lockout_succeeded"})
      end
    end

    it "returns false for failed lockout" do
      refresh_frame(nx, new_frame: {"mechanism" => "pg_stop"})
      expect(sshable).to receive(:_cmd).with(
        "timeout 10 sudo pg_ctlcluster 18 main stop -m immediate",
        timeout: 15,
      ).and_raise(Sshable::SshError.new("", "", "", "", ""))
      expect { nx.start }.to exit({"msg" => "lockout_failed"})
    end

    it "returns false for AWS API failures" do
      refresh_frame(nx, new_frame: {"mechanism" => "detach_nic"})
      expect(nx).to receive(:lockout_with_detach_nic).and_raise(Aws::EC2::Errors::ServiceError.new(nil, "boom"))
      expect { nx.start }.to exit({"msg" => "lockout_failed"})
    end
  end

  describe "#lockout_with_pg_stop" do
    it "stops postgres and returns true on success" do
      expect(sshable).to receive(:_cmd).with(
        "timeout 10 sudo pg_ctlcluster 18 main stop -m immediate",
        timeout: 15,
      ).and_return(true)
      expect { nx.lockout_with_pg_stop }.not_to raise_error
    end
  end

  describe "#lockout_with_hba" do
    it "applies lockout pg_hba.conf and returns true on success" do
      expect(sshable).to receive(:_cmd).with(
        "timeout 10 sudo postgres/bin/lockout-hba 18",
        timeout: 15,
      ).and_return(true)
      expect { nx.lockout_with_hba }.not_to raise_error
    end
  end

  describe "#lockout_with_host_routing" do
    let(:vm_host) { create_vm_host(location_id:) }
    let(:vm_host_sshable) { vm_host.sshable }

    before do
      server.vm.update(vm_host_id: vm_host.id)
      allow(server.vm).to receive(:vm_host).and_return(vm_host)
    end

    it "applies lockout host routing and returns true on success" do
      expect(vm_host_sshable).to receive(:_cmd).with(
        "timeout 10 sudo ip link set vetho#{server.vm.inhost_name} down",
        timeout: 15,
      ).and_return(true)
      expect { nx.lockout_with_host_routing }.not_to raise_error
    end
  end

  describe "#lockout_with_detach_nic" do
    let(:aws_location) {
      loc = Location.create(name: "us-west-2", display_name: "aws-us-west-2", ui_name: "aws-us-west-2", visible: true, provider: "aws", project_id: project.id)
      LocationCredentialAws.create_with_id(loc, access_key: "k", secret_key: "s")
      LocationAz.create(location_id: loc.id, az: "a", zone_id: "usw2-az1")
      loc
    }
    let(:aws_resource) { create_postgres_resource(project:, location_id: aws_location.id) }
    let(:aws_server) { create_postgres_server(resource: aws_resource, timeline: postgres_timeline) }
    let(:aws_nx) { described_class.new(aws_server.strand) }
    let(:ec2_client) { Aws::EC2::Client.new(stub_responses: true) }

    before do
      NicAwsResource.create_with_id(aws_server.vm.nics.first, network_interface_id: "eni-abc")
      allow(Aws::EC2::Client).to receive(:new).with(credentials: anything, region: "us-west-2").and_return(ec2_client)
    end

    it "looks up the attachment id and detaches the tracked ENI" do
      ec2_client.stub_responses(:describe_network_interfaces, network_interfaces: [{network_interface_id: "eni-abc", attachment: {attachment_id: "eni-attach-123"}}])
      expect(ec2_client).to receive(:detach_network_interface).with(attachment_id: "eni-attach-123", force: true).and_call_original
      expect { aws_nx.lockout_with_detach_nic }.not_to raise_error
    end
  end

  describe "firewall_reset" do
    let(:v1) { Google::Cloud::Compute::V1 }
    let(:gcp_location) { Location[name: "gcp-us-central1"] }
    let(:gcp_server) {
      LocationCredentialGcp.create_with_id(gcp_location, project_id: "test-gcp-project",
        service_account_email: "test@test-gcp-project.iam.gserviceaccount.com", credentials_json: "{}")
      vm = Prog::Vm::Nexus.assemble_with_sshable(project.id, location_id: gcp_location.id, size: "c4a-standard-4", arch: "arm64").subject
      vm.update(ephemeral_net6: "2600:1900:4000:1234:0:1::/96")
      VmGcpResource.create_with_id(vm, location_az_id: LocationAz.create(location_id: gcp_location.id, az: "b").id)
      NicGcpResource.create_with_id(vm.user_nic, vpc_name: "ubicloud-vpc", subnet_name: "ubicloud-subnet")
      server = PostgresServer.create(
        timeline: create_postgres_timeline(location_id: gcp_location.id), resource: create_postgres_resource(project:, location_id: gcp_location.id),
        vm_id: vm.id, is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17",
      )
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
      server
    }
    let(:gcp_nx) {
      described_class.new(gcp_server.strand).tap { refresh_frame(it, new_frame: {"mechanism" => "firewall_reset"}) }
    }
    let(:prefix) { "ubicloud-fence-#{gcp_server.vm.ubid}-" }
    let(:compute_client) { instance_double(v1::Instances::Rest::Client) }
    let(:zone_operations_client) { instance_double(v1::ZoneOperations::Rest::Client) }
    let(:policies_client) { instance_double(v1::NetworkFirewallPolicies::Rest::Client) }
    let(:global_operations_client) { instance_double(v1::GlobalOperations::Rest::Client) }

    before do
      allow(v1::Instances::Rest::Client).to receive(:new).and_return(compute_client)
      allow(v1::ZoneOperations::Rest::Client).to receive(:new).and_return(zone_operations_client)
      allow(v1::NetworkFirewallPolicies::Rest::Client).to receive(:new).and_return(policies_client)
      allow(v1::GlobalOperations::Rest::Client).to receive(:new).and_return(global_operations_client)
    end

    def expect_failed(error, error_class = nil)
      expect(Clog).to receive(:emit).with("GCP lockout failed", {gcp_lockout_failed: {server_ubid: gcp_server.ubid, mechanism: "firewall_reset", error:, error_class:}}).and_call_original
      expect { yield }.to exit({"msg" => "lockout_failed"})
    end

    def expect_succeeded
      expect(Clog).to receive(:emit).with("Fenced unresponsive primary", {fenced_unresponsive_primary: {server_ubid: gcp_server.ubid, mechanism: "firewall_reset"}}).and_call_original
      expect { yield }.to exit({"msg" => "lockout_succeeded"})
    end

    gcp_errors = [
      Google::Cloud::PermissionDeniedError.new("denied"),
      Google::Cloud::DeadlineExceededError.new("timed out"),
      Google::Auth::CredentialsError.new("bad key"),
      Signet::AuthorizationError.new("no token"),
      Signet::ParseError.new("bad response"),
      Signet::UnexpectedStatusError.new("status 500"),
    ]

    it "commits a deadline before the first API call" do
      expect { gcp_nx.start }.to hop("add_deny_rules")
      expect(frame_value(gcp_nx, "gcp_deadline")).to be_within(1).of(Time.now.to_i + 60)
    end

    it "fails once the deadline passes" do
      refresh_frame(gcp_nx, new_values: {"gcp_deadline" => Time.now.to_i - 1})
      expect_failed("deadline passed") { gcp_nx.before_run }
    end

    it "runs the label before the deadline" do
      refresh_frame(gcp_nx, new_values: {"gcp_deadline" => Time.now.to_i + 10})
      expect(gcp_nx.before_run).to be_nil
    end

    describe "#add_deny_rules" do
      def expect_policy(*rules)
        expect(policies_client).to receive(:get).with(project: "test-gcp-project", firewall_policy: "ubicloud-vpc")
          .and_return(v1::FirewallPolicy.new(rules: rules.map { |priority, rule_name| v1::FirewallPolicyRule.new(priority:, rule_name:) }))
      end

      def expect_add_rules(count)
        added = []
        expect(policies_client).to receive(:add_rule).exactly(count).times do |project:, firewall_policy:, firewall_policy_rule_resource:|
          expect([project, firewall_policy]).to eq(["test-gcp-project", "ubicloud-vpc"])
          added << firewall_policy_rule_resource
          instance_double(Gapic::GenericLRO::Operation, name: "op-#{added.size}")
        end
        added
      end

      it "denies the Postgres ports on both addresses at the first free priorities" do
        expect_policy([0, "other"], [2, "other"])
        added = expect_add_rules(2)
        expect { gcp_nx.add_deny_rules }.to hop("wait_deny_rules")
        expect(frame_value(gcp_nx, "deny_rule_ops")).to eq(["op-1", "op-2"])

        expect(added.map { [it.priority, it.rule_name, it.direction, it.action, it.match.src_ip_ranges.to_a, it.match.dest_ip_ranges.to_a] }).to eq([
          [1, "#{prefix}ipv4", "INGRESS", "deny", ["0.0.0.0/0"], ["#{gcp_server.vm.user_nic.private_ipv4_address}/32"]],
          [3, "#{prefix}ipv6", "INGRESS", "deny", ["::/0"], [gcp_server.vm.ephemeral_net6.to_s]],
        ])
        expect(added.map { |rule| rule.match.layer4_configs.map { [it.ip_protocol, it.ports.to_a] } }).to all(eq([["tcp", ["5432", "6432"]]]))
        expect(added.map(&:description)).to all(eq("Ubicloud lockout of #{gcp_server.ubid}"))
      end

      it "adds only the rules that are missing" do
        expect_policy([0, "#{prefix}ipv4"])
        added = expect_add_rules(1)
        expect { gcp_nx.add_deny_rules }.to hop("wait_deny_rules")
        expect(added.map { [it.priority, it.rule_name] }).to eq([[1, "#{prefix}ipv6"]])
        expect(frame_value(gcp_nx, "deny_rule_ops")).to eq(["op-1"])
      end

      it "adds only the IPv4 rule when the VM has no IPv6 range" do
        gcp_server.vm.update(ephemeral_net6: nil)
        expect_policy
        added = expect_add_rules(1)
        expect { gcp_nx.add_deny_rules }.to hop("wait_deny_rules")
        expect(added.map(&:rule_name)).to eq(["#{prefix}ipv4"])
      end

      it "retries when the policy is busy" do
        expect_policy
        expect(policies_client).to receive(:add_rule).and_raise(Google::Cloud::InvalidArgumentError.new("Invalid value: rules have the same priorities"))
        expect { gcp_nx.add_deny_rules }.to nap(1)
      end

      it "fails when the policy rejects the rule" do
        expect_policy
        expect(policies_client).to receive(:add_rule).and_raise(Google::Cloud::InvalidArgumentError.new("bad range"))
        expect_failed("bad range", "Google::Cloud::InvalidArgumentError") { gcp_nx.add_deny_rules }
      end

      gcp_errors.each do |error|
        it "fails on #{error.class}" do
          expect(policies_client).to receive(:get).and_raise(error)
          expect_failed(error.message, error.class.name) { gcp_nx.add_deny_rules }
        end
      end
    end

    describe "#wait_deny_rules" do
      before do
        refresh_frame(gcp_nx, new_values: {"deny_rule_ops" => ["op-1", "op-2"]})
      end

      def expect_polls(*ops)
        ops.each_with_index do |op, i|
          expect(global_operations_client).to receive(:get).with(project: "test-gcp-project", operation: "op-#{i + 1}").and_return(op)
        end
      end

      it "naps while an operation runs" do
        expect_polls(v1::Operation.new(status: :DONE), v1::Operation.new(status: :RUNNING))
        expect { gcp_nx.wait_deny_rules }.to nap(1)
      end

      it "resets the instance once every rule is in place" do
        expect_polls(v1::Operation.new(status: :DONE), v1::Operation.new(status: :DONE))
        expect { gcp_nx.wait_deny_rules }.to hop("reset_vm")
      end

      it "resets the instance when no rule had to be added" do
        refresh_frame(gcp_nx, new_values: {"deny_rule_ops" => []})
        expect { gcp_nx.wait_deny_rules }.to hop("reset_vm")
      end

      it "adds the rules again when an operation failed" do
        error = v1::Error.new(errors: [v1::Errors.new(code: "CONFLICT", message: "priority taken")])
        expect_polls(v1::Operation.new(status: :DONE), v1::Operation.new(status: :DONE, error:))
        expect(Clog).to receive(:emit).with("GCP fence rule failed, retrying", {gcp_fence_rule_retry: {server_ubid: gcp_server.ubid, error: "priority taken (code: CONFLICT)"}}).and_call_original
        expect { gcp_nx.wait_deny_rules }.to hop("add_deny_rules")
      end

      it "fails when the poll raises" do
        expect(global_operations_client).to receive(:get).and_raise(Google::Cloud::UnavailableError.new("down"))
        expect_failed("down", "Google::Cloud::UnavailableError") { gcp_nx.wait_deny_rules }
      end
    end

    describe "#reset_vm" do
      it "resets the instance and saves the operation" do
        expect(compute_client).to receive(:reset).with(
          project: "test-gcp-project", zone: "us-central1-b", instance: gcp_server.vm.name, request_id: gcp_server.strand.id,
        ).and_return(instance_double(Gapic::GenericLRO::Operation, name: "op-reset"))
        expect { gcp_nx.reset_vm }.to hop("wait_reset_vm")
        expect(frame_value(gcp_nx, "reset_vm")).to eq("name" => "op-reset", "scope" => "zone", "scope_value" => "us-central1-b")
      end

      it "succeeds when the instance is already gone" do
        expect(compute_client).to receive(:reset).and_raise(Google::Cloud::NotFoundError.new("gone"))
        expect_succeeded { gcp_nx.reset_vm }
      end

      gcp_errors.each do |error|
        it "fails on #{error.class}" do
          expect(compute_client).to receive(:reset).and_raise(error)
          expect_failed(error.message, error.class.name) { gcp_nx.reset_vm }
        end
      end
    end

    describe "#wait_reset_vm" do
      before do
        refresh_frame(gcp_nx, new_values: {"reset_vm" => {"name" => "op-reset", "scope" => "zone", "scope_value" => "us-central1-b"}})
      end

      def expect_poll(op)
        expect(zone_operations_client).to receive(:get).with(project: "test-gcp-project", zone: "us-central1-b", operation: "op-reset").and_return(op)
      end

      it "naps while the operation runs" do
        expect_poll(v1::Operation.new(status: :RUNNING))
        expect { gcp_nx.wait_reset_vm }.to nap(1)
      end

      it "succeeds when the operation is done" do
        expect_poll(v1::Operation.new(status: :DONE))
        expect_succeeded { gcp_nx.wait_reset_vm }
      end

      it "fails when the operation is done with an error" do
        expect_poll(v1::Operation.new(status: :DONE, error: v1::Error.new(errors: [v1::Errors.new(code: "NOT_READY", message: "not running")])))
        expect_failed("not running (code: NOT_READY)") { gcp_nx.wait_reset_vm }
      end

      it "fails when the poll raises" do
        expect(zone_operations_client).to receive(:get).and_raise(Google::Cloud::UnavailableError.new("down"))
        expect_failed("down", "Google::Cloud::UnavailableError") { gcp_nx.wait_reset_vm }
      end
    end
  end
end
