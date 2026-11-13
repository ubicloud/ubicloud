# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "terraform: ubicloud_vm (generated)" do
  it "creates with the derived request body and schedules destroy" do
    runner = tf_runner("vm_basic.tf.erb", name: "tf-vm")
    runner.apply

    vm = Vm.first(project_id: tf_project.id)
    expect(vm.name).to eq "tf-vm"
    expect(vm.ip4_enabled).to be true

    attrs = runner.state_resources.find { it["address"] == "ubicloud_vm.vm" }["values"]
    expect(attrs.values_at("name", "enable_ip4", "storage_size")).to eq ["tf-vm", true, 40]

    runner.destroy

    # vm teardown is async: the API's contract is the semaphore, not
    # the row (routes-spec doctrine); terraform state is already clear.
    expect(SemSnap.new(vm.id).set?("destroy")).to be true
    expect(runner.state_resources).to be_nil
  end
end
