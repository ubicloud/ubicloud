# frozen_string_literal: true

require_relative "spec_helper"

# An allocation that commits while another allocation's query runs is not in
# that query's snapshot. This needs two real DB connections, so it opts out of
# the wrapping rollback-only transaction and cleans up its own committed rows.
RSpec.describe VmHost, :no_db_transaction do
  let(:vm_host) { create_vm_host }
  let(:vm) { create_vm }

  before { @skip_leaked_thread_check = true }

  after do
    DB[:assigned_vm_address].where(dst_vm_id: vm.id).delete
    DB[:vm].where(id: vm.id).delete
    DB[:project].where(id: vm.project_id).delete
    DB[:ipv4_address].where(cidr: DB[:address].where(routed_to_host_id: vm_host.id).select(:cidr)).delete
    DB[:address].where(routed_to_host_id: vm_host.id).delete
    DB[:vm_host].where(id: vm_host.id).delete
    DB[:sshable].where(id: vm_host.id).delete
  end

  # Unlike pg_stat_activity, pg_locks is not kept fixed for the rest of a
  # transaction after its first read, so it can be polled in one.
  def waiting_for_lock?(**lock)
    DB[:pg_locks].where(granted: false, database: DB[:pg_database].where(datname: Sequel.function(:current_database)).select(:oid), **lock).count > 0
  end

  it "skips the address that another allocation assigned while the query ran" do
    Address.create(cidr: "128.0.0.0/32", routed_to_host_id: vm_host.id).populate_ipv4_addresses
    gate = 0x1b4

    # Stop the query after it takes its snapshot and before it locks a row,
    # until the other allocation has committed.
    picker = described_class[vm_host.id]
    expect(picker).to receive(:assigned_subnets_dataset).and_wrap_original do |m|
      m.call.where(Sequel.lit("(SELECT true FROM pg_advisory_xact_lock_shared(?))", gate))
    end

    pick = nil
    waited = false
    DB.transaction do
      ip, address = vm_host.ip4_random_vm_network
      DB.get(Sequel.function(:pg_advisory_xact_lock, gate))
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: ip.to_s, address_id: address.id)
      pick = Thread.new { DB.transaction { picker.ip4_random_vm_network } }
      deadline = Time.now + 10
      sleep 0.01 until (waited = waiting_for_lock?(locktype: "advisory", objid: gate)) || Time.now > deadline
    end

    expect(waited).to be true
    # The query's snapshot does not have the assignment, but the address's
    # row has a newer version, which the query locks and then tests again.
    expect(pick.join(10)&.value).to eq([nil, nil])
  end
end
