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
        "timeout 10 sudo pg_ctlcluster 17 main stop -m immediate",
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
        "timeout 10 sudo pg_ctlcluster 17 main stop -m immediate",
        timeout: 15,
      ).and_return(true)
      expect { nx.lockout_with_pg_stop }.not_to raise_error
    end
  end

  describe "#lockout_with_hba" do
    it "applies lockout pg_hba.conf and returns true on success" do
      expect(sshable).to receive(:_cmd).with(
        "timeout 10 sudo postgres/bin/lockout-hba 17",
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
end
