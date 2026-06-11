# frozen_string_literal: true

require_relative "../../../spec_helper"

# Two-connection specs for the shared GCP VPC attach/destroy race:
# single-connection specs cannot catch a silently dropped gcp_vpc row
# lock, so these drive real concurrent transactions through both commit
# orders, outside the wrapping rollback-only transaction.
RSpec.describe Prog::Vnet::Gcp::SubnetNexus, :no_db_transaction do
  let(:tag) { SecureRandom.hex(4) }
  let(:created_subnet_ids) { [] }
  let(:project) { Project.create(name: "vpc-race-#{tag}") }
  let(:location) {
    Location.create(name: "vpc-race-gcp-#{tag}", provider: "gcp", project_id: project.id,
      display_name: "VPC Race GCP", ui_name: "VPC Race GCP", visible: true)
  }
  let(:credential) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "vpc-race@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }
  let(:gcp_vpc) {
    vpc = GcpVpc.create(
      project_id: project.id,
      location_id: location.id,
      name: "ubicloud-#{project.ubid}-#{location.ubid}",
    )
    Strand.create_with_id(vpc, prog: "Vnet::Gcp::VpcNexus", label: "wait")
    vpc
  }

  def make_subnet(idx)
    subnet = PrivateSubnet.create(
      name: "vpc-race-ps-#{tag}-#{idx}",
      location_id: location.id, project_id: project.id,
      net6: "fd10:dd#{format("%02x", idx)}::/64",
      net4: "10.#{200 + idx}.0.0/26",
      state: "waiting",
    )
    Strand.create_with_id(subnet, prog: "Vnet::Gcp::SubnetNexus", label: "start")
    created_subnet_ids << subnet.id
    subnet
  end

  after do
    DB.transaction do
      strand_ids = created_subnet_ids + [gcp_vpc.id]
      DB[:semaphore].where(strand_id: strand_ids).delete
      DB[:private_subnet_gcp_vpc].where(gcp_vpc_id: gcp_vpc.id).delete
      DB[:strand].where(id: strand_ids).delete
      DB[:private_subnet].where(id: created_subnet_ids).delete
      DB[:gcp_vpc].where(id: gcp_vpc.id).delete
      DB[:location_credential_gcp].where(id: location.id).delete
      DB[:location].where(id: location.id).delete
      DB[:project].where(id: project.id).delete
    end
  end

  it "blocks start on the held vpc row lock until the incr_destroy commits, then naps without attaching" do
    # Commit the lets on the main connection before the threads start.
    vpc_id = gcp_vpc.id
    subnet = make_subnet(1)
    nx = described_class.new(subnet.strand)

    t1_has_lock = Queue.new
    t1_may_release = Queue.new
    t1_error = nil
    t2_result = nil

    # Simulates finish_destroy: hold the row lock across the incr,
    # releasing only at commit.
    t1 = Thread.new do
      DB.transaction do
        GcpVpc.where(id: vpc_id).for_no_key_update.first
        t1_has_lock.push(DB.get(Sequel.function(:pg_backend_pid)))
        gcp_vpc.incr_destroy
        expect(t1_may_release.pop(timeout: 5)).to be true
      end
    rescue => e
      t1_error = e
    end

    begin
      t1_pid = t1_has_lock.pop(timeout: 5)
      expect(t1_pid).to be_a(Integer)

      t2_pid_queue = Queue.new
      t2 = Thread.new do
        DB.synchronize do
          t2_pid_queue.push(DB.get(Sequel.function(:pg_backend_pid)))
          nx.start
        end
        t2_result = :proceeded
      rescue Prog::Base::Nap => e
        t2_result = [:napped, e.seconds]
      rescue Prog::Base::Hop
        t2_result = :hopped
      rescue => e
        t2_result = [:error, e.class.name, e.message]
      end

      # Wait until T2's backend is blocked by T1's; without the lock
      # it would attach and finish as :hopped instead.
      t2_pid = t2_pid_queue.pop(timeout: 5)
      expect(t2_pid).to be_a(Integer)
      blocking = lambda { DB.get(Sequel.function(:pg_blocking_pids, t2_pid)).to_a }
      500.times do
        break if blocking.call == [t1_pid]
        sleep 0.01
      end
      expect(blocking.call).to eq([t1_pid])
      expect(t2_result).to be_nil

      t1_may_release.push(true)
      expect(t1.join(5)).to eq(t1)
      expect(t2.join(5)).to eq(t2)
    ensure
      t1_may_release.push(true) if t1.alive?
      [t1, t2].each do |t|
        next unless t&.alive?
        t.kill
        t.join
      end
    end

    expect(t1_error).to be_nil
    expect(t2_result).to eq([:napped, 5])
    expect(DB[:private_subnet_gcp_vpc].where(private_subnet_id: subnet.id).count).to eq(0)
    expect(gcp_vpc.destroy_set?).to be(true)
  end

  it "makes finish_destroy's locked recount observe a committed attach and skip incr_destroy" do
    attacher = make_subnet(1)
    destroyer = make_subnet(2)
    DB[:private_subnet_gcp_vpc].insert(private_subnet_id: destroyer.id, gcp_vpc_id: gcp_vpc.id)

    t1_error = nil
    t1 = Thread.new do
      described_class.new(attacher.strand).start
    rescue Prog::Base::Hop
      # expected: attach committed, hop to wait_vpc_ready
    rescue => e
      t1_error = e
    end
    expect(t1.join(5)).to eq(t1)
    expect(t1_error).to be_nil
    expect(DB[:private_subnet_gcp_vpc].where(private_subnet_id: attacher.id).count).to eq(1)

    credential
    nx_destroyer = described_class.new(destroyer.strand)
    subnetworks = instance_double(Google::Cloud::Compute::V1::Subnetworks::Rest::Client)
    expect(subnetworks).to receive(:get).and_raise(Google::Cloud::NotFoundError.new("not found"))
    allow(nx_destroyer.send(:credential)).to receive(:subnetworks_client).and_return(subnetworks)

    expect { nx_destroyer.finish_destroy }.to exit({"msg" => "subnet destroyed"})
    expect(gcp_vpc.destroy_set?).to be(false)
    expect(destroyer).not_to exist
    expect(DB[:private_subnet_gcp_vpc].where(private_subnet_id: attacher.id).count).to eq(1)
  ensure
    if t1&.alive?
      t1.kill
      t1.join
    end
  end
end
