# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ParseableServer do
  subject(:parseable_server) {
    server = described_class.create(
      parseable_resource_id: parseable_resource.id,
      vm_id: vm.id,
      cert: "dummy-cert",
      cert_key: "dummy-cert-key",
    )
    Strand.create_with_id(server, prog: "Parseable::ParseableServerNexus", label: "wait")
    server
  }

  let(:project) { Project.create(name: "parseable-test-project") }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID,
      net4: "10.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }
  let(:vm) {
    Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "test-vm", private_subnet_id: private_subnet.id,
      location_id: Location::HETZNER_FSN1_ID,
    ).subject.update(ephemeral_net6: "fdfa:b5aa:14a3:4a3d::/64")
  }
  let(:parseable_resource) {
    ParseableResource.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "test-parseable",
      admin_user: "admin",
      admin_password: "dummy-password",
      root_cert_1: "root_cert_1",
      root_cert_key_1: "root_cert_key_1",
      root_cert_2: "root_cert_2",
      root_cert_key_2: "root_cert_key_2",
      blob_storage_access_key: "access-key-1234",
      blob_storage_secret_key: "secret-key-5678",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100,
      project_id: project.id,
    )
  }

  it "returns public ipv6 address properly" do
    expect(parseable_server.public_ipv6_address).to eq("fdfa:b5aa:14a3:4a3d::2")
  end

  it "returns ip6_url with brackets and port 8000" do
    expect(parseable_server.ip6_url).to eq("https://[#{parseable_server.public_ipv6_address}]:8000")
  end

  it "returns false for needs_event_loop_for_pulse_check?" do
    expect(parseable_server.needs_event_loop_for_pulse_check?).to be false
  end

  describe "#endpoint" do
    it "returns the ip6_url in development mode" do
      expect(Config).to receive(:development?).and_return(true)
      expect(parseable_server.endpoint).to eq(parseable_server.ip6_url)
    end

    it "returns the hostname-based url in production mode" do
      expect(Config).to receive_messages(development?: false, is_e2e: false, parseable_host_name: "parseable.example.com")
      expect(parseable_server.endpoint).to eq("https://test-parseable.parseable.example.com:8000")
    end
  end

  describe "#client" do
    it "builds a Parseable::Client with resource credentials" do
      expect(Parseable::Client).to receive(:new).with(
        endpoint: parseable_server.endpoint,
        ssl_ca_data: parseable_resource.root_certs,
        username: parseable_resource.admin_user,
        password: parseable_resource.admin_password,
      )
      parseable_server.client
    end
  end

  describe "#init_health_monitor_session" do
    it "returns session hash with parseable_client" do
      client = instance_double(Parseable::Client)
      expect(parseable_server).to receive(:client).and_return(client)

      result = parseable_server.init_health_monitor_session
      expect(result).to eq({parseable_client: client})
    end
  end

  describe "#check_pulse" do
    it "returns up reading when health check passes" do
      client = instance_double(Parseable::Client)
      session = {parseable_client: client}

      expect(client).to receive(:healthy?).and_return(true)

      result = parseable_server.check_pulse(session:, previous_pulse: {reading: "down", reading_rpt: 3, reading_chg: Time.now - 60})
      expect(result[:reading]).to eq("up")
      expect(result[:reading_rpt]).to eq(1)
      expect(result[:reading_chg]).to be_within(1).of(Time.now)
    end

    it "returns down reading when health check returns false" do
      client = instance_double(Parseable::Client)
      session = {parseable_client: client}

      expect(client).to receive(:healthy?).and_return(false)

      result = parseable_server.check_pulse(session:, previous_pulse: {reading: "up", reading_rpt: 2, reading_chg: Time.now - 30})
      expect(result[:reading]).to eq("down")
      expect(result[:reading_rpt]).to eq(1)
      expect(result[:reading_chg]).to be_within(1).of(Time.now)
    end

    it "returns down reading when health check raises" do
      client = instance_double(Parseable::Client)
      session = {parseable_client: client}

      expect(client).to receive(:healthy?).and_raise(RuntimeError)

      result = parseable_server.check_pulse(session:, previous_pulse: {reading: "up", reading_rpt: 1, reading_chg: Time.now - 10})
      expect(result[:reading]).to eq("down")
      expect(result[:reading_rpt]).to eq(1)
      expect(result[:reading_chg]).to be_within(1).of(Time.now)
    end

    it "increments checkup semaphore when server has been down long enough" do
      client = instance_double(Parseable::Client)
      session = {parseable_client: client}
      expect(client).to receive(:healthy?).and_return(false)
      previous_pulse = {reading: "down", reading_rpt: 5, reading_chg: Time.now - 60}

      parseable_server.check_pulse(session:, previous_pulse:)
      expect(parseable_server.reload.checkup_set?).to be true
    end

    it "does not increment checkup when checkup is already set" do
      client = instance_double(Parseable::Client)
      session = {parseable_client: client}
      expect(client).to receive(:healthy?).and_return(false)
      parseable_server.incr_checkup
      previous_pulse = {reading: "down", reading_rpt: 5, reading_chg: Time.now - 60}

      parseable_server.check_pulse(session:, previous_pulse:)
      expect(parseable_server.reload.strand.semaphores.count { it.name == "checkup" }).to eq(1)
    end
  end
end
