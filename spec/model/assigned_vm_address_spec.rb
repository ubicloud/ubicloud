# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AssignedVmAddress do
  let(:vm_host) { create_vm_host }
  let(:vm) { create_vm }

  before { Address.create(vm_host:, cidr: "128.0.0.0/31").populate_ipv4_addresses }

  def assigned
    DB[:ipv4_address].where(cidr: "128.0.0.0/31").order(:ip).select_map(:assigned)
  end

  it "marks its address assigned, with or without an address_id" do
    described_class.create(dst_vm_id: vm.id, ip: "128.0.0.1")
    expect(assigned).to eq [false, true]
  end

  it "marks its address free when it is destroyed" do
    described_class.create(dst_vm_id: vm.id, ip: "128.0.0.1").destroy
    expect(assigned).to eq [false, false]
  end

  it "moves the mark when its ip changes" do
    described_class.create(dst_vm_id: vm.id, ip: "128.0.0.0").update(ip: "128.0.0.1")
    expect(assigned).to eq [false, true]
  end

  it "leaves the address row alone when an update does not change ip" do
    assignment = described_class.create(dst_vm_id: vm.id, ip: "128.0.0.1")
    row = DB[:ipv4_address].where(ip: "128.0.0.1")
    ctid = row.get(:ctid)
    # Any update of the row would give it a new ctid.
    described_class.where(id: assignment.id).update(dst_vm_id: create_vm.id)
    described_class.where(id: assignment.id).update(ip: "128.0.0.1")
    expect(row.get(:ctid)).to eq ctid
    expect(assigned).to eq [false, true]
  end

  it "marks an address assigned when its subnet is populated after the assignment" do
    described_class.create(dst_vm_id: vm.id, ip: "128.0.0.2")
    Address.create(vm_host:, cidr: "128.0.0.2/31").populate_ipv4_addresses
    expect(DB[:ipv4_address].where(cidr: "128.0.0.2/31").order(:ip).select_map(:assigned)).to eq [true, false]
  end
end
