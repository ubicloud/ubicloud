# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "vm_host" do
  let(:vm_host) { Prog::Vm::HostNexus.assemble("127.0.0.1").vm_host }

  it "can not access without login" do
    visit "/vm-host"

    expect(page.title).to eq("Ubicloud - Login")
  end

  describe "authenticated" do
    before do
      login
    end

    it "can list no virtual machine hosts" do
      visit "/vm-host"

      expect(page.title).to eq("Ubicloud - VM Hosts")
      expect(page).to have_content "No virtual machine host"

      click_link "New Virtual Machine Host"
      expect(page.title).to eq("Ubicloud - Add VM Host")
    end

    it "can add new virtual machine host" do
      visit "/vm-host/create"

      expect(page.title).to eq("Ubicloud - Add VM Host")

      fill_in "hostname", with: "127.0.0.1"
      choose option: "hetzner-hel1"

      click_button "Add"

      expect(page.title).to eq("Ubicloud - VM Hosts")
      expect(page).to have_content "'127.0.0.1' host will be ready in a few minutes"
      expect(VmHost.count).to eq(1)
    end

    it "can list ssh agent public keys at development" do
      expect(Config).to receive(:development?).and_return(true)
      expect(Net::SSH::Authentication::Agent).to receive(:connect) do
        agent = instance_double(Net::SSH::Authentication::Agent, close: nil)
        expect(agent).to receive(:identities).and_return(["dummy-key"])
        expect(SshKey).to receive(:public_key).and_return(["dummy-key"])
        agent
      end

      visit "/vm-host/create"

      expect(page.title).to eq("Ubicloud - Add VM Host")
      expect(page).to have_content "dummy-key"
    end

    it "can show virtual machine host details" do
      shadow = Clover::VmHostShadow.new(vm_host)
      visit "/vm-host"

      expect(page.title).to eq("Ubicloud - VM Hosts")
      expect(page).to have_content shadow.host

      click_link "Show", href: "/vm-host/#{shadow.id}"

      expect(page.title).to eq("Ubicloud - #{shadow.host}")
      expect(page).to have_content shadow.host
    end

    it "raises not found when virtual machine host not exists" do
      visit "/vm-host/08s56d4kaj94xsmrnf5v5m3mav"

      expect(page.title).to eq("Ubicloud - Page not found")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "Page not found"
    end
  end
end
