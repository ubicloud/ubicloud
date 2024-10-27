# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe MonitorableResource do
  let(:postgres_server) { PostgresServer.new { _1.id = "c068cac7-ed45-82db-bf38-a003582b36ee" } }
  let(:r_w_event_loop) { described_class.new(postgres_server) }
  let(:vm_host) { VmHost.new { _1.id = "46683a25-acb1-4371-afe9-d39f303e44b4" } }
  let(:r_without_event_loop) { described_class.new(vm_host) }

  describe "#open_resource_session" do
    it "returns if session is not nil and pulse reading is up" do
      r_w_event_loop.instance_variable_set(:@session, "not nil")
      r_w_event_loop.instance_variable_set(:@pulse, {reading: "up"})

      expect(postgres_server).not_to receive(:reload)
      r_w_event_loop.open_resource_session
    end

    it "sets session to resource's init_health_monitor_session" do
      expect(postgres_server).to receive(:reload).and_return(postgres_server)
      expect(postgres_server).to receive(:init_health_monitor_session).and_return("session")
      expect { r_w_event_loop.open_resource_session }.to change { r_w_event_loop.instance_variable_get(:@session) }.from(nil).to("session")
    end

    it "sets deleted to true if resource is deleted" do
      expect(postgres_server).to receive(:reload).and_raise(Sequel::NoExistingObject)
      expect { r_w_event_loop.open_resource_session }.to change(r_w_event_loop, :deleted).from(false).to(true)
    end

    it "ignores exception if it is not Sequel::NoExistingObject" do
      expect(postgres_server).to receive(:reload).and_raise(StandardError)
      expect { r_w_event_loop.open_resource_session }.not_to raise_error
    end
  end

  describe "#process_event_loop" do
    before do
      # We are monkeypatching the sleep method here to avoid the actual sleep.
      # We also use it to flip the @run_event_loop flag to true, so that the
      # loop in the process_event_loop method can exit.
      def r_w_event_loop.sleep(duration)
        @run_event_loop = true
      end
    end

    it "returns if session is nil or resource does not need event loop" do
      skip_if_frozen
      expect(Thread).not_to receive(:new)

      # session is nil
      r_w_event_loop.process_event_loop

      # resource does not need event loop
      r_without_event_loop.instance_variable_set(:@session, "not nil")
      r_without_event_loop.process_event_loop
    end

    it "creates a new thread and runs the event loop" do
      skip_if_frozen
      session = {ssh_session: instance_double(Net::SSH::Connection::Session)}
      r_w_event_loop.instance_variable_set(:@session, session)
      expect(Thread).to receive(:new).and_yield
      expect(session[:ssh_session]).to receive(:loop)
      r_w_event_loop.process_event_loop
    end

    it "swallows exception and logs it if event loop fails" do
      skip_if_frozen
      session = {ssh_session: instance_double(Net::SSH::Connection::Session)}
      r_w_event_loop.instance_variable_set(:@session, session)
      expect(Thread).to receive(:new).and_yield
      expect(session[:ssh_session]).to receive(:loop).and_raise(StandardError)
      expect(Clog).to receive(:emit)
      expect(r_w_event_loop).to receive(:close_resource_session)
      r_w_event_loop.process_event_loop
    end
  end

  describe "#check_pulse" do
    it "calls check_pulse on resource and sets pulse" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "up"})
      expect { r_w_event_loop.check_pulse }.to change { r_w_event_loop.instance_variable_get(:@pulse) }.from({}).to({reading: "up"})
    end

    it "swallows exception and logs it if check_pulse fails" do
      expect(vm_host).to receive(:check_pulse).and_raise(StandardError)
      expect(Clog).to receive(:emit)
      expect { r_without_event_loop.check_pulse }.not_to raise_error
    end

    it "waits for the pulse thread to finish" do
      pulse_thread = Thread.new {}
      expect(pulse_thread).to receive(:join)
      r_w_event_loop.instance_variable_set(:@pulse_thread, pulse_thread)
      r_w_event_loop.check_pulse
    end

    it "logs the pulse if reading is not up" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "down", reading_rpt: 5})
      expect(Clog).to receive(:emit)
      r_w_event_loop.check_pulse
    end

    it "does not log the pulse if reading is up and reading_rpt is not every 5th reading" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "up", reading_rpt: 3})
      expect(Clog).not_to receive(:emit)
      r_w_event_loop.check_pulse
    end

    it "logs the pulse if reading is up and reading_rpt is every 5th reading" do
      expect(postgres_server).to receive(:check_pulse).and_return({reading: "up", reading_rpt: 6})
      expect(Clog).to receive(:emit)
      r_w_event_loop.check_pulse
    end
  end

  describe "#close_resource_session" do
    it "returns if session is nil" do
      session = {ssh_session: instance_double(Net::SSH::Connection::Session)}
      expect(session[:ssh_session]).not_to receive(:shutdown!)
      expect(session).to receive(:nil?).and_return(true)
      r_w_event_loop.instance_variable_set(:@session, session)
      r_w_event_loop.close_resource_session
    end

    it "shuts down and closes the session" do
      session = {ssh_session: instance_double(Net::SSH::Connection::Session)}
      expect(session[:ssh_session]).to receive(:shutdown!)
      expect(session[:ssh_session]).to receive(:close)
      r_w_event_loop.instance_variable_set(:@session, session)
      r_w_event_loop.close_resource_session
    end
  end

  describe "#force_stop_if_stuck" do
    it "does nothing if pulse check is not stuck" do
      skip_if_frozen
      expect(Kernel).not_to receive(:exit!)

      # not locked
      r_w_event_loop.force_stop_if_stuck

      # not timed out
      r_w_event_loop.instance_variable_get(:@mutex).lock
      r_w_event_loop.instance_variable_set(:@pulse_check_started_at, Time.now)
      r_w_event_loop.force_stop_if_stuck
      r_w_event_loop.instance_variable_get(:@mutex).unlock
    end

    it "triggers Kernel.exit if pulse check is stuck" do
      r_w_event_loop.instance_variable_get(:@mutex).lock
      r_w_event_loop.instance_variable_set(:@pulse_check_started_at, Time.now - 200)
      expect(Clog).to receive(:emit).at_least(:once)
      r_w_event_loop.force_stop_if_stuck
      r_w_event_loop.instance_variable_get(:@mutex).unlock
    end
  end

  describe "#lock_no_wait" do
    it "does not yield if mutex is locked" do
      r_w_event_loop.instance_variable_get(:@mutex).lock
      expect { |b| r_w_event_loop.lock_no_wait(&b) }.not_to yield_control
      r_w_event_loop.instance_variable_get(:@mutex).unlock
    end

    it "yields if mutex is not locked" do
      expect { |b| r_w_event_loop.lock_no_wait(&b) }.to yield_control
    end
  end
end
