# frozen_string_literal: true

require_relative "../lib/ember_config"

RSpec.describe EmberConfig do
  it "names slots so they sort and so the name is a legal unix user" do
    expect(described_class.slot_name(0)).to eq("emslot0000")
    expect(described_class.slot_name(128)).to eq("emslot0128")
  end

  it "gives each slot a directory under the VM root" do
    expect(described_class.slot_dir(3)).to eq("/vm/emslot0003")
  end
end
