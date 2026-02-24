# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe MonitorableResource do
  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "test-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }

  let(:postgres_resource) {
    PostgresResource.create(
      name: "pg-test",
      superuser_password: "dummy",
      ha_type: "none",
      target_version: "16",
      location_id:,
      project_id: project.id,
      target_vm_size: "standard-2",
      target_storage_size_gib: 64
    )
  }

  let(:postgres_timeline) { PostgresTimeline.create(location_id:) }

  let(:postgres_server) {
    vm = Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "pg-vm", private_subnet_id: private_subnet.id,
      location_id:, unix_user: "ubi"
    ).subject
    PostgresServer.create(
      timeline: postgres_timeline,
      resource_id: postgres_resource.id,
      vm_id: vm.id,
      is_representative: true,
      synchronization_status: "ready",
      timeline_access: "push",
      version: "16"
    )
  }

  let(:vm_host) { create_vm_host }
  let(:vm) { create_vm }

  let(:r_w_event_loop) { described_class.new(postgres_server) }
  let(:r_without_event_loop) { described_class.new(vm_host) }

  describe "#open_resource_session" do
    it "returns if session is not nil and pulse reading is up" do
      r_w_event_loop.instance_variable_set(:@session, "not nil")
      r_w_event_loop.instance_variable_set(:@pulse, {reading: "up"})

      expect(postgres_server).not_to receive(:reload)
      r_w_event_loop.open_resource_session
    end

    it "sets session to resource's init_health_monitor_session" do
      expect(postgres_server).to receive(:init_health_monitor_session).and_return("session")
      expect { r_w_event_loop.open_resource_session }.to change { r_w_event_loop.instance_variable_get(:@session) }.from(nil).to("session")
    end

    it "sets deleted to true if resource is deleted" do
      postgres_server.destroy
      expect { r_w_event_loop.open_resource_session }.to change(r_w_event_loop, :deleted).from(false).to(true)
    end

    it "raises the exception if it is not Sequel::NoExistingObject" do
      expect(postgres_server).to receive(:reload).and_raise(StandardError)
      expect { r_w_event_loop.open_resource_session }.to raise_error(StandardError)
    end
  end

  describe "#check_pulse" do
    it "does not create thread if session is nil or resource does not need event loop" do
      expect(Thread).not_to receive(:new)

      # session is nil
      r_w_event_loop.check_pulse

      # resource does not need event loop
      r_without_event_loop.instance_variable_set(:@session, {})
      r_without_event_loop.check_pulse
    end

    it "marks resource deleted if an exception is raised and the resource no longer exists" do
      resource = r_without_event_loop.resource
      resource.destroy
      expect(resource).to receive(:check_pulse).and_raise(RuntimeError)
      expect(Clog).to receive(:emit).with("Resource is deleted.", {resource_deleted: {ubid: resource.ubid}})
      r_without_event_loop.instance_variable_set(:@session, {})
      r_without_event_loop.check_pulse
      expect(r_without_event_loop.deleted).to be true
    end

    it "handles checking pulses for attached resources" do
      attached_resource = r_without_event_loop.attached_resources[vm.id] = described_class.new(vm)
      session = {ssh_session: :foo}
      expect(attached_resource).to receive(:session=).with(session).and_call_original
      expect(attached_resource).to receive(:check_pulse)
      r_without_event_loop.instance_variable_set(:@session, session)
      r_without_event_loop.check_pulse
      expect(r_without_event_loop.deleted).to be false
      expect(attached_resource.deleted).to be false
    end

    it "handles deleting attached resources that no longer exist" do
      attached_resource = r_without_event_loop.attached_resources[vm.id] = described_class.new(vm)
      vm.destroy
      session = {ssh_session: :foo}
      expect(attached_resource).to receive(:session=).with(session).and_call_original
      expect(attached_resource.resource).to receive(:check_pulse).and_raise(RuntimeError)
      r_without_event_loop.instance_variable_set(:@session, session)
      r_without_event_loop.check_pulse
      expect(r_without_event_loop.deleted).to be false
      expect(attached_resource.deleted).to be true
      expect(r_without_event_loop.attached_resources).to eq({})
    end

    it "handles attached resources check pulses that clears the session" do
      attached_resource = r_without_event_loop.attached_resources[vm.id] = described_class.new(vm)
      vm2 = create_vm
      attached_resource2 = r_without_event_loop.attached_resources[vm2.id] = described_class.new(vm2)
      session = {ssh_session: :foo}
      expect(attached_resource).to receive(:session=).with(session).and_call_original
      expect(attached_resource.resource).to receive(:check_pulse) do |session:, previous_pulse:|
        session.clear
      end
      expect(attached_resource2).not_to receive(:session=)
      expect(attached_resource2.resource).not_to receive(:check_pulse)
      r_without_event_loop.instance_variable_set(:@session, session)
      r_without_event_loop.check_pulse
      expect(r_without_event_loop.deleted).to be false
      expect(attached_resource.deleted).to be false
      expect(r_without_event_loop.attached_resources.keys).to eq([vm.id, vm2.id])
      expect(session.keys).to eq [:last_pulse]
    end

    it "swallows exception and logs it if event loop fails" do
      session = {ssh_session: Net::SSH::Connection::Session.allocate}
      r_w_event_loop.instance_variable_set(:@session, session)
      expect(session[:ssh_session]).to receive(:shutdown!)
      expect(session[:ssh_session]).to receive(:close)
      expect(Thread).to receive(:new).and_call_original
      expect(session[:ssh_session]).to receive(:loop).and_raise(StandardError)
      expect(Clog).to receive(:emit).at_least(:once).and_call_original
      r_w_event_loop.check_pulse
    end

    it "swallows exception and logs it if check_pulse fails" do
      session = {ssh_session: Net::SSH::Connection::Session.allocate}
      r_without_event_loop.instance_variable_set(:@session, session)
      expect(vm_host).to receive(:check_pulse).and_raise(StandardError)
      expect(Clog).to receive(:emit).and_call_original
      expect { r_without_event_loop.check_pulse }.not_to raise_error
    end
  end

  describe "#check_pulse with session and event loop" do
    let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }

    before do
      r_w_event_loop.instance_variable_set(:@session, session)
      expect(session[:ssh_session]).to receive(:loop)
    end

    it "creates a new thread and runs the event loop" do
      expect(Thread).to receive(:new).and_call_original
      r_w_event_loop.check_pulse
    end

    it "calls check_pulse on resource and sets pulse" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "up"})
      expect { r_w_event_loop.check_pulse }.to change { r_w_event_loop.instance_variable_get(:@pulse) }.from({}).to({reading: "up"})
    end

    it "swallows exception and logs it if check_pulse fails" do
      expect(postgres_server).to receive(:check_pulse).and_raise(StandardError)
      expect(Clog).to receive(:emit).and_call_original
      expect { r_w_event_loop.check_pulse }.not_to raise_error
    end

    it "does not log the pulse if reading is up and reading_rpt is not every 5th and reading_rpt is large enough" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "up", reading_rpt: 13})
      expect(Clog).not_to receive(:emit).and_call_original
      r_w_event_loop.check_pulse
    end

    it "logs the pulse if reading is not up" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "down", reading_rpt: 13})
      expect(Clog).to receive(:emit).and_call_original
      r_w_event_loop.check_pulse
    end

    it "logs the pulse if reading is up and reading_rpt is every 5th reading" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "up", reading_rpt: 6})
      expect(Clog).to receive(:emit).and_call_original
      r_w_event_loop.check_pulse
    end

    it "logs the pulse if reading is up and reading_rpt is recent enough" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "up", reading_rpt: 3})
      expect(Clog).to receive(:emit).and_call_original
      r_w_event_loop.check_pulse
    end
  end

  [IOError.new("closed stream"), Errno::ECONNRESET.new("recvfrom(2)")].each do |ex|
    describe "#check_pulse", "stale connection retry behavior with #{ex.class}" do
      let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }

      before do
        r_w_event_loop.instance_variable_set(:@session, session)
        expect(session[:ssh_session]).to receive(:loop)
      end

      it "retries if the last pulse is not set" do
        expect(postgres_server).to receive(:check_pulse).and_raise(ex)
        second_session = Net::SSH::Connection::Session.allocate
        expect(postgres_server).to receive(:init_health_monitor_session).and_return(second_session)
        expect(session[:ssh_session]).to receive(:shutdown!)
        expect(session).to receive(:merge!).with(second_session)
        expect(postgres_server).to receive(:check_pulse).and_return({reading: "up", reading_rpt: 1})
        r_w_event_loop.check_pulse
      end

      it "does not retry if the connection is fresh" do
        session[:last_pulse] = Time.now - 1
        expect(postgres_server).to receive(:check_pulse).and_raise(ex)
        expect(Clog).to receive(:emit).and_call_original
        expect { r_w_event_loop.check_pulse }.not_to raise_error
      end

      it "is up on a retry on a stale connection that works the second time" do
        session[:last_pulse] = Time.now - 10
        expect(postgres_server).to receive(:check_pulse).and_raise(ex)
        second_session = Net::SSH::Connection::Session.allocate
        expect(postgres_server).to receive(:init_health_monitor_session).and_return(second_session)
        expect(session[:ssh_session]).to receive(:shutdown!)
        expect(session).to receive(:merge!).with(second_session)
        expect(postgres_server).to receive(:check_pulse).and_return({reading: "up", reading_rpt: 1})
        r_w_event_loop.check_pulse
      end

      it "is down if consecutive errors are raised even on a stale connection" do
        session[:last_pulse] = Time.now - 10
        expect(postgres_server).to receive(:check_pulse).and_raise(ex)
        second_session = Net::SSH::Connection::Session.allocate
        expect(postgres_server).to receive(:init_health_monitor_session).and_return(second_session)
        expect(session[:ssh_session]).to receive(:shutdown!)
        expect(session).to receive(:merge!).with(second_session)
        expect(postgres_server).to receive(:check_pulse).and_return(ex)
        expect(Clog).to receive(:emit).and_call_original
        expect { r_w_event_loop.check_pulse }.not_to raise_error
      end

      it "is down for a matching exception without a matching message" do
        session[:last_pulse] = Time.now - 10
        expect(postgres_server).to receive(:check_pulse).and_raise(ex.class.new("something else"))
        expect(Clog).to receive(:emit).and_call_original
        expect { r_w_event_loop.check_pulse }.not_to raise_error
      end
    end
  end
end
