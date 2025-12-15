# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe VictoriaMetricsServer do
  subject(:vms) {
    vmr = VictoriaMetricsResource.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "victoria-metrics-cluster",
      admin_user: "vm-admin",
      admin_password: "dummy-password",
      root_cert_1: "dummy-root-cert-1",
      root_cert_2: "dummy-root-cert-2",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
      project_id: project.id
    )

    server = described_class.create(
      victoria_metrics_resource_id: vmr.id,
      vm_id: vm.id,
      cert: "cert",
      cert_key: "cert-key"
    )
    Strand.create_with_id(server, prog: "VictoriaMetrics::VictoriaMetricsServerNexus", label: "wait")
    server
  }

  let(:project) { Project.create(name: "vm-test-project") }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "test-ps", project_id: project.id, location_id: Location::HETZNER_FSN1_ID,
      net4: "10.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }
  let(:vm) {
    Prog::Vm::Nexus.assemble_with_sshable(
      project.id, name: "test-vm", private_subnet_id: private_subnet.id,
      location_id: Location::HETZNER_FSN1_ID
    ).subject.update(ephemeral_net6: "fdfa:b5aa:14a3:4a3d::/64")
  }

  it "returns public ipv6 address properly" do
    expect(vms.public_ipv6_address).to eq("fdfa:b5aa:14a3:4a3d::2")
  end

  it "returns victoria metrics resource properly" do
    expect(vms.resource.name).to eq("victoria-metrics-cluster")
  end

  it "redacts the cert column" do
    expect(described_class.redacted_columns).to include(:cert)
  end

  describe "#init_health_monitor_session" do
    it "initiates a new health monitor session" do
      socket_path = File.join(Dir.pwd, "var", "health_monitor_sockets", "vn_fdfa:b5aa:14a3:4a3d::2")
      unix_server = instance_double(UNIXServer)
      forward = instance_double(Net::SSH::Service::Forward)
      session = Net::SSH::Connection::Session.allocate
      client = instance_double(VictoriaMetrics::Client)

      sshable = vms.vm.sshable

      expect(FileUtils).to receive(:rm_rf).with(socket_path)
      expect(FileUtils).to receive(:mkdir_p).with(socket_path)
      expect(UNIXServer).to receive(:new).with(File.join(socket_path, "health_monitor_socket")).and_return(unix_server)
      expect(forward).to receive(:local)
      expect(session).to receive(:forward).and_return(forward)
      expect(sshable).to receive(:start_fresh_session).and_return(session)
      expect(VictoriaMetrics::Client).to receive(:new).with(
        endpoint: vms.endpoint,
        ssl_ca_data: vms.resource.root_certs,
        socket: File.join("unix://", socket_path, "health_monitor_socket"),
        username: vms.resource.admin_user,
        password: vms.resource.admin_password
      ).and_return(client)

      result = vms.init_health_monitor_session
      expect(result).to eq({
        ssh_session: session,
        victoria_metrics_client: client
      })
    end
  end

  describe "#check_pulse" do
    let(:fixed_time) { Time.now }

    it "returns up when health check succeeds" do
      client = instance_double(VictoriaMetrics::Client)
      session = {victoria_metrics_client: client}

      expect(client).to receive(:health).and_return(true)
      expect(vms).to receive(:aggregate_readings).with(
        previous_pulse: {reading: "down", reading_rpt: 3, reading_chg: fixed_time - 60},
        reading: "up"
      ).and_return({reading: "up", reading_rpt: 1, reading_chg: fixed_time})

      result = vms.check_pulse(session: session, previous_pulse: {reading: "down", reading_rpt: 3, reading_chg: fixed_time - 60})
      expect(result).to eq({reading: "up", reading_rpt: 1, reading_chg: fixed_time})
    end

    it "returns down when health check fails" do
      client = instance_double(VictoriaMetrics::Client)
      session = {victoria_metrics_client: client}

      expect(client).to receive(:health).and_return(false)
      expect(vms).to receive(:aggregate_readings).with(
        previous_pulse: {reading: "up", reading_rpt: 2, reading_chg: fixed_time - 30},
        reading: "down"
      ).and_return({reading: "down", reading_rpt: 1, reading_chg: fixed_time})

      result = vms.check_pulse(session: session, previous_pulse: {reading: "up", reading_rpt: 2, reading_chg: fixed_time - 30})
      expect(result).to eq({reading: "down", reading_rpt: 1, reading_chg: fixed_time})
    end

    it "returns down when health check raises an exception" do
      client = instance_double(VictoriaMetrics::Client)
      session = {victoria_metrics_client: client}

      expect(client).to receive(:health).and_raise(RuntimeError)
      expect(vms).to receive(:aggregate_readings).with(
        previous_pulse: {reading: "up", reading_rpt: 1, reading_chg: fixed_time - 10},
        reading: "down"
      ).and_return({reading: "down", reading_rpt: 1, reading_chg: fixed_time})

      result = vms.check_pulse(session: session, previous_pulse: {reading: "up", reading_rpt: 1, reading_chg: fixed_time - 10})
      expect(result).to eq({reading: "down", reading_rpt: 1, reading_chg: fixed_time})
    end

    it "increments checkup semaphore when down for a while" do
      client = instance_double(VictoriaMetrics::Client)
      session = {victoria_metrics_client: client}

      expect(client).to receive(:health).and_return(false)
      previous_pulse = {reading: "down", reading_rpt: 5, reading_chg: fixed_time - 60}

      vms.check_pulse(session: session, previous_pulse: previous_pulse)
      expect(vms.reload.checkup_set?).to be true
    end

    it "does not increment checkup semaphore when already set" do
      client = instance_double(VictoriaMetrics::Client)
      session = {victoria_metrics_client: client}

      expect(client).to receive(:health).and_return(false)
      vms.incr_checkup  # Pre-set the semaphore
      previous_pulse = {reading: "down", reading_rpt: 5, reading_chg: fixed_time - 60}

      vms.check_pulse(session: session, previous_pulse: previous_pulse)
      expect(vms.reload.strand.semaphores.count { it.name == "checkup" }).to eq(1)
    end
  end

  describe "#client" do
    it "creates a client with the correct parameters in prod" do
      expect(VictoriaMetrics::Client).to receive(:new).with(
        endpoint: vms.endpoint,
        ssl_ca_data: vms.resource.root_certs,
        socket: nil,
        username: vms.resource.admin_user,
        password: vms.resource.admin_password
      )

      vms.client
    end

    it "creates a client with a socket when specified" do
      socket = "unix:///path/to/socket"
      expect(VictoriaMetrics::Client).to receive(:new).with(
        endpoint: vms.endpoint,
        ssl_ca_data: vms.resource.root_certs,
        socket: socket,
        username: vms.resource.admin_user,
        password: vms.resource.admin_password
      )

      vms.client(socket: socket)
    end
  end

  describe "#endpoint" do
    it "returns the endpoint with hostname in production" do
      expect(Config).to receive(:development?).and_return(false)
      expect(Config).to receive(:is_e2e).and_return(false)
      expect(vms.endpoint).to eq("https://#{vms.resource.hostname}:8427")
    end

    it "returns the endpoint with ip6_url in development" do
      expect(Config).to receive(:development?).and_return(true)
      expect(vms.endpoint).to eq(vms.ip6_url)
    end
  end

  describe "#needs_event_loop_for_pulse_check?" do
    it "returns true" do
      expect(vms.needs_event_loop_for_pulse_check?).to be true
    end
  end

  describe "#private_ipv4_address" do
    it "returns the vms private ipv4 address" do
      # VM created by assemble_with_sshable has a NIC with private IPv4
      # Verify it returns the same value as vm.private_ipv4
      expect(vms.private_ipv4_address).to eq(vms.vm.private_ipv4.to_s)
    end
  end
end
