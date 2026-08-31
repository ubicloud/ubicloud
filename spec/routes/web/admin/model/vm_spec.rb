# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "Vm" do
  include AdminModelSpecHelper

  before do
    @instance = create_vm
    admin_account_setup_and_login
  end

  it "displays the Vm instance page correctly" do
    click_link "Vm"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Vm - Browse"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - Vm #{@instance.ubid}"
  end

  it "displays the hypervisor a Vm is pinned to" do
    project = Project.create(name: "test-project")
    vm = Prog::Vm::Nexus.assemble("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGWmPgJE test@example.com", project.id, name: "pinned-vm", ch_version: "53.0").subject

    click_link "Vm"
    expect(page).to have_content "ch 53.0"

    click_link vm.admin_label
    expect(page).to have_content "ch 53.0"
  end
end
