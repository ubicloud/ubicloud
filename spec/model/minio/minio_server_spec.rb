# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe MinioServer do
  subject(:ms) {
    vm = create_vm
    mc = MinioCluster.create(
      location_id: Location::HETZNER_FSN1_ID,
      name: "minio-cluster-name",
      admin_user: "minio-admin",
      admin_password: "dummy-password",
      root_cert_1: "dummy-root-cert-1",
      root_cert_2: "dummy-root-cert-2",
      project_id: vm.project_id
    )
    mp = MinioPool.create(
      cluster_id: mc.id,
      start_index: 0,
      server_count: 1,
      drive_count: 1,
      storage_size_gib: 100,
      vm_size: "standard-2"
    )

    described_class.create(
      minio_pool_id: mp.id,
      vm_id: vm.id,
      index: 0,
      cert: "cert"
    )
  }

  before do
    allow(ms.vm).to receive(:ephemeral_net4).and_return("1.2.3.4")
  end

  it "returns hostname properly" do
    expect(ms.hostname).to eq("minio-cluster-name0.minio.ubicloud.com")
  end

  it "returns private ipv4 address properly" do
    nic = instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("192.168.0.0/32"))
    expect(ms.vm).to receive(:nics).and_return([nic]).at_least(:once)
    expect(ms.private_ipv4_address).to eq("192.168.0.0")
  end

  it "returns public ipv4 address properly" do
    expect(ms.public_ipv4_address).to eq("1.2.3.4")
  end

  it "returns minio cluster properly" do
    expect(ms.cluster.name).to eq("minio-cluster-name")
  end

  describe "#minio_volumes" do
    it "returns minio volumes properly for a single drive single server cluster" do
      expect(ms.minio_volumes).to eq("/minio/dat1")
    end

    it "returns minio volumes properly for a multi drive single server cluster" do
      ms.pool.update(drive_count: 4)
      expect(ms.minio_volumes).to eq("/minio/dat{1...4}")
    end

    it "returns minio volumes properly for a multi drive multi server cluster" do
      ms.pool.update(drive_count: 4, server_count: 2)
      expect(ms.minio_volumes).to eq("https://minio-cluster-name{0...1}.minio.ubicloud.com:9000/minio/dat{1...2}")
    end
  end

  it "initiates a new health monitor session" do
    forward = instance_double(Net::SSH::Service::Forward)
    expect(forward).to receive(:local)
    session = instance_double(Net::SSH::Connection::Session)
    expect(session).to receive(:forward).and_return(forward)
    sshable = instance_double(Sshable)
    expect(sshable).to receive(:start_fresh_session).and_return(session)
    expect(ms.vm).to receive(:sshable).and_return(sshable)
    expect(UNIXServer).to receive(:new)
    expect(Minio::Client).to receive(:new)
    expect(ms).to receive(:private_ipv4_address).and_return("192.168.1.1")
    ms.init_health_monitor_session
  end

  it "checks pulse using endpoint for multiple servers" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      minio_client: Minio::Client.new(endpoint: "https://1.2.3.4:9000", access_key: "dummy-key", secret_key: "dummy-secret", ssl_ca_data: "data")
    }

    expect(ms.vm).to receive(:ephemeral_net4).and_return("1.2.3.4").at_least(:once)
    expect(ms).not_to receive(:incr_checkup)
    ms.pool.update(server_count: 2)

    stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok"}]}]}))
    ms.check_pulse(session: session, previous_pulse: {reading: "down", reading_rpt: 5, reading_chg: Time.now - 30})

    stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [
      {state: "online", endpoint: "1.2.3.5:9000", drives: [{state: "ok"}]},
      {state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "faulty"}]}
    ]}))
    ms.check_pulse(session: session, previous_pulse: {})

    stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "offline", endpoint: "1.2.3.4:9000"}]}))
    ms.check_pulse(session: session, previous_pulse: {})
  end

  it "checks pulse without endpoint for single server" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      minio_client: Minio::Client.new(endpoint: "https://1.2.3.4:9000", access_key: "dummy-key", secret_key: "dummy-secret", ssl_ca_data: "data")
    }

    expect(ms.vm).not_to receive(:ephemeral_net4)
    expect(ms).not_to receive(:incr_checkup)

    stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "ok"}]}]}))
    ms.check_pulse(session: session, previous_pulse: {reading: "down", reading_rpt: 5, reading_chg: Time.now - 30})

    stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "online", endpoint: "1.2.3.4:9000", drives: [{state: "faulty"}]}]}))
    ms.check_pulse(session: session, previous_pulse: {})

    stub_request(:get, "https://1.2.3.4:9000/minio/admin/v3/info").to_return(status: 200, body: JSON.generate({servers: [{state: "offline", endpoint: "1.2.3.4:9000"}]}))
    ms.check_pulse(session: session, previous_pulse: {})
  end

  it "increments checkup semaphore if pulse is down for a while" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      minio_client: instance_double(Minio::Client)
    }

    expect(session[:minio_client]).to receive(:admin_info).and_raise(RuntimeError)
    expect(ms).to receive(:incr_checkup)
    ms.check_pulse(session: session, previous_pulse: {reading: "down", reading_rpt: 5, reading_chg: Time.now - 30})
  end

  it "returns endpoint properly" do
    expect(ms.vm).to receive(:ephemeral_net4).and_return("1.1.1.1")
    expect(ms.endpoint).to eq("1.1.1.1:9000")

    expect(ms.cluster).to receive(:dns_zone).and_return("something")
    expect(ms.endpoint).to eq("minio-cluster-name0.minio.ubicloud.com:9000")
  end

  it "needs event loop for pulse check" do
    expect(ms).to be_needs_event_loop_for_pulse_check
  end

  it "generates /etc/hosts entries properly when there are multiple servers" do
    servers = [instance_double(described_class, id: ms.id, public_ipv4_address: "1.1.1.1", hostname: "minio-cluster-name1.minio.ubicloud.com"),
      instance_double(described_class, id: 2, public_ipv4_address: "1.1.1.2", hostname: "minio-cluster-name2.minio.ubicloud.com")]
    mc = instance_double(MinioCluster, name: "minio-cluster-name", servers: servers)
    expect(ms).to receive(:cluster).and_return(mc).at_least(:once)
    expect(ms.generate_etc_hosts_entry).to eq("127.0.0.1 minio-cluster-name0.minio.ubicloud.com\n1.1.1.2 minio-cluster-name2.minio.ubicloud.com")
  end

  describe "#url" do
    before do
      minio_project = Project.create(name: "default")
      allow(Config).to receive(:minio_service_project_id).and_return(minio_project.id)
    end

    it "returns url properly" do
      DnsZone.create(project_id: Config.minio_service_project_id, name: Config.minio_host_name)
      expect(ms.server_url).to eq("https://minio-cluster-name.minio.ubicloud.com:9000")
    end

    it "returns ip address when dns zone is not found" do
      expect(ms.vm).to receive(:ephemeral_net4).and_return("10.10.10.10")
      expect(ms.server_url).to eq("https://10.10.10.10:9000")
    end
  end
end
