# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm" do
  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public-key", name: "dummy-vm").vm
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  it "can not access without login" do
    visit "/vm"

    expect(page.title).to eq("Ubicloud - Login")
  end

  describe "authenticated" do
    before do
      login
    end

    it "can list no virtual machines" do
      visit "/vm"

      expect(page.title).to eq("Ubicloud - Virtual Machines")
      expect(page).to have_content "No virtual machines"

      click_link "New Virtual Machine"
      expect(page.title).to eq("Ubicloud - Create Virtual Machine")
    end

    it "can create new virtual machine" do
      visit "/vm/create"

      expect(page.title).to eq("Ubicloud - Create Virtual Machine")

      fill_in "Name", with: "dummy-vm"
      choose option: "hetzner-hel1"
      choose option: "ubuntu-jammy"
      choose option: "standard-1"

      click_button "Create"

      expect(page.title).to eq("Ubicloud - Virtual Machines")
      expect(page).to have_content "'dummy-vm' will be ready in a few minutes"
      expect(Vm.count).to eq(1)
    end

    it "can show virtual machine details" do
      shadow = Clover::VmShadow.new(vm)
      visit "/vm"

      expect(page.title).to eq("Ubicloud - Virtual Machines")
      expect(page).to have_content shadow.name

      click_link "Show", href: "/vm/#{shadow.id}"

      expect(page.title).to eq("Ubicloud - #{shadow.name}")
      expect(page).to have_content shadow.name
    end

    it "raises not found when virtual machine not exists" do
      visit "/vm/08s56d4kaj94xsmrnf5v5m3mav"

      expect(page.title).to eq("Ubicloud - Page not found")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "Page not found"
    end

    it "delete" do
      shadow = Clover::VmShadow.new(vm)
      visit "/vm/#{shadow.id}"

      # We send delete request manually instead of just clicking to button because delete action triggered by JavaScript.
      # UI tests run without a JavaScript enginer.
      btn = find ".delete-btn"
      page.driver.delete btn["data-url"], {_csrf: btn["data-csrf"]}

      expect(page.body).to eq("Deleting #{vm.id}")
      expect(SemSnap.new(vm.id).set?("destroy")).to be true
    end
  end
end
