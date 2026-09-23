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

  describe "Serial Log" do
    def create_serial_log(**args)
      RunCommand.create(vm_id: @instance.id, command: "fetch_serial_log", status: "succeeded", output: "boot ok", run_at: Time.now, **args)
    end

    before { @instance.update(vm_host_id: create_vm_host.id, allocated_at: Time.now) }

    it "is not offered for a Vm that has not been allocated yet" do
      @instance.update(allocated_at: nil)
      visit "/model/Vm/#{@instance.ubid}"
      expect(find_by_id("action-list").all("a").map(&:text)).not_to include("Serial Log")
    end

    it "starts a fetch when the Vm has no serial log yet" do
      visit "/model/Vm/#{@instance.ubid}"
      click_link "Serial Log"
      expect(page).to have_content "Fetching serial console log"
      expect(page).to have_no_button "Fetch Latest"
      expect(@instance.most_recent_serial_log.status).to eq "created"
    end

    it "shows the output of the most recent fetch and starts a new fetch on request" do
      create_serial_log(output: "\e[0;32mboot ok\e[0m")
      visit "/model/Vm/#{@instance.ubid}/serial_log"
      expect(page).to have_content "Fetched at"
      expect(page.find("pre").text).to eq "boot ok"

      click_button "Fetch Latest"
      expect(page).to have_current_path "/model/Vm/#{@instance.ubid}/serial_log"
      expect(page).to have_content "Fetching serial console log"
      expect(@instance.most_recent_serial_log.status).to eq "created"
    end

    it "shows that the most recent fetch failed" do
      create_serial_log(status: "failed", output: nil)
      visit "/model/Vm/#{@instance.ubid}/serial_log"
      expect(page).to have_content "Failed to fetch serial console log"
      expect(page).to have_button "Fetch Latest"
    end

    it "shows the error when a fetch cannot be started" do
      @instance.update(vm_host_id: nil)
      dont_raise_admin_errors do
        visit "/model/Vm/#{@instance.ubid}/serial_log"
        expect(page).to have_content "InvalidRequest: VM has no assigned host"
      end
    end
  end
end
