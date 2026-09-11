# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::DnsZone::SetupDnsServerVm, :no_db_transaction do
  let(:project) { Project.create(name: "dns-configure-concurrency") }
  let(:servers) { [] }
  let(:workers) { [] }
  let(:zones) { [] }

  after do
    DB.transaction do
      vm_ids = workers.map(&:subject_id)
      strand_ids = workers.map { it.strand.id } + zones.map(&:id)
      DB[:semaphore].where(strand_id: strand_ids).delete
      DB[:strand].where(id: workers.map { it.strand.id }).delete
      DB[:strand].where(id: zones.map(&:id)).delete
      DB[:dns_servers_vms].where(vm_id: vm_ids).delete
      DB[:dns_servers_dns_zones].where(dns_server_id: servers.map(&:id)).delete
      DB[:dns_zone].where(id: zones.map(&:id)).delete
      DB[:dns_server].where(id: servers.map(&:id)).delete
      DB[:vm].where(id: vm_ids).delete
      DB[:sshable].where(id: vm_ids).delete
      project.destroy
    end
  end

  def make_server
    server = DnsServer.create(name: "ns-#{DnsServer.generate_uuid}.example.com")
    servers << server
    server
  end

  def make_zone(server)
    zone = DnsZone.create(project_id: project.id, name: "zone-#{zones.length}.example.com")
    Strand.create_with_id(zone, prog: "DnsZone::DnsZoneNexus", label: "wait")
    zone.add_dns_server(server)
    zones << zone
    zone
  end

  def make_worker(server, zone)
    vm = create_vm(project_id: project.id, name: "dns-#{workers.length}")
    Sshable.create_with_id(vm)
    server.add_vm(vm)
    child = Prog::DnsZone::DnsZoneNexus.new(zone.strand).bud(described_class,
      {"subject_id" => vm.id, "dns_server_id" => server.id}, "configure")
    worker = described_class.new(child)
    workers << worker
    worker
  end

  def run_configure(worker)
    DB.transaction do
      catch(:prog_return) { worker.configure }
    end
  end

  def expect_configuration(worker)
    expect(worker.sshable).to receive(:_cmd).with("true").and_return("")
    expect(worker.sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: worker.knot_config).ordered
    expect(worker.sshable).to receive(:_cmd).with("sudo -u knot knotc reload").ordered
  end

  def with_zone_lock(zone)
    acquired = Queue.new
    release = Queue.new
    holder = Thread.new do
      DB.transaction do
        key = Digest::SHA2.digest(zone.id).unpack1("q>").abs
        expect(DB.get(Sequel.function(:pg_try_advisory_xact_lock, key))).to be true
        acquired.push(true)
        expect(release.pop(timeout: 5)).to be true
      end
    end
    expect(acquired.pop(timeout: 5)).to be true
    yield
  ensure
    release.push(true)
    expect(holder.join(5)).to eq holder
    holder.value
  end

  ["write", "reload", "failed write", "failed reload"].each do |operation|
    it "serializes shared-zone workers through #{operation} and releases the locks afterwards" do
      server = make_server
      first_zone = make_zone(server)
      second_zone = make_zone(server)
      first = make_worker(server, first_zone)
      second = make_worker(server, second_zone)
      entered = Queue.new
      release = Queue.new

      expect(first.sshable).to receive(:_cmd).with("true").and_return("")
      pause = lambda do
        entered.push(DB.get(Sequel.function(:pg_backend_pid)))
        expect(release.pop(timeout: 5)).to be true
      end
      expect(first.sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: first.knot_config) do
        pause.call if operation.end_with?("write")
        raise IOError, "write failed" if operation == "failed write"
      end
      unless operation == "failed write"
        expect(first.sshable).to receive(:_cmd).with("sudo -u knot knotc reload") do
          pause.call unless operation == "write"
          raise IOError, "reload failed" if operation == "failed reload"
        end
      end

      thread = Thread.new do
        run_configure(first)
      rescue IOError => e
        e
      end
      begin
        backend = entered.pop(timeout: 5)
        expect(backend).to be_a Integer
        expect(backend).not_to eq DB.get(Sequel.function(:pg_backend_pid))
        expect(second.sshable).to receive(:_cmd).with("true").and_return("")
        expect(run_configure(second)).to have_attributes(seconds: 5)

        release.push(true)
        expect(thread.join(5)).to eq thread
        if operation.start_with?("failed")
          expect(thread.value).to be_a IOError
        else
          expect(thread.value).to have_attributes(exitval: {"msg" => "configured"})
        end
        expect_configuration(second)
        expect(run_configure(second)).to have_attributes(exitval: {"msg" => "configured"})
      ensure
        release.push(true)
        expect(thread.join(5)).to eq thread
      end
    end
  end

  it "locks every served zone and releases partial acquisitions when another zone is busy" do
    server = make_server
    3.times { make_zone(server) }
    ordered = zones.sort_by(&:id)
    worker = make_worker(server, ordered.first)
    earlier_server = make_server
    ordered.first.add_dns_server(earlier_server)
    earlier_worker = make_worker(earlier_server, ordered.first)

    with_zone_lock(ordered.last) do
      expect(worker.sshable).to receive(:_cmd).with("true").and_return("")
      DB.synchronize do
        locks = DB[:pg_locks].where(pid: DB.get(Sequel.function(:pg_backend_pid)), locktype: "advisory", granted: true)
        DB.transaction do
          expect { worker.configure }.to nap(5)
          expect(locks.count).to eq 2
        end
        expect(locks.count).to eq 0
      end

      expect_configuration(earlier_worker)
      expect(run_configure(earlier_worker)).to have_attributes(exitval: {"msg" => "configured"})
    end
    expect_configuration(worker)
    expect(run_configure(worker)).to have_attributes(exitval: {"msg" => "configured"})
  end

  it "coordinates different DNS servers sharing a zone" do
    server = make_server
    zone = make_zone(server)
    other_server = make_server
    zone.add_dns_server(other_server)
    worker = make_worker(other_server, zone)

    with_zone_lock(zone) do
      expect(worker.sshable).to receive(:_cmd).with("true").and_return("")
      expect(run_configure(worker)).to have_attributes(seconds: 5)
    end
    expect_configuration(worker)
    expect(run_configure(worker)).to have_attributes(exitval: {"msg" => "configured"})
  end

  it "allows unrelated DNS fleets to configure while a zone lock is held" do
    busy_zone = make_zone(make_server)
    server = make_server
    worker = make_worker(server, make_zone(server))

    with_zone_lock(busy_zone) do
      expect_configuration(worker)
      expect(run_configure(worker)).to have_attributes(exitval: {"msg" => "configured"})
    end
  end
end
