# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmHostInventory do
  subject(:inventory) {
    described_class.create do
      it.id = vm_host.id
      it.server_model = "AX102"
      it.cpu = "AMD Ryzen 9 7950X3D"
      it.memory = "128GB"
      it.storage = "2x 1.92TB NVMe SSD"
      it.uplink = "1Gbps"
      it.monthly_price = 109.9
      it.currency = "EUR"
    end
  }

  let(:vm_host) { create_vm_host }

  it "can be accessed through its vm host" do
    inventory
    expect(vm_host.inventory.id).to eq inventory.id
  end

  it "is destroyed together with its vm host" do
    inventory
    vm_host.destroy
    expect(inventory).not_to exist
  end

  it "refreshes updated_at on update" do
    original = inventory.updated_at
    inventory.update(monthly_price: 94.0)
    expect(inventory.updated_at).to be > original
  end

  it "does not allow negative monthly price" do
    expect {
      inventory.update(monthly_price: -1)
    }.to raise_error(Sequel::ValidationFailed, "monthly_price is invalid")
  end

  it "does not allow unexpected currencies" do
    expect {
      inventory.update(currency: "TRY")
    }.to raise_error(Sequel::ValidationFailed, "currency is invalid")
  end

  it "requires monthly price and currency to be set together" do
    expect {
      inventory.update(currency: nil)
    }.to raise_error(Sequel::ValidationFailed, "monthly_price and currency is invalid")
  end
end
