# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe VmInitScript do
  it "implements a max length validation on the init_script column" do
    vm = described_class.new(script: "a", init_script: "a" * 2001)
    expect(vm.valid?).to be false
    vm.init_script = "a" * 2000
    expect(vm.valid?).to be true
  end
end
