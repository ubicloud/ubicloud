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
      create_account
      login
    end

    describe "#vm_host_allowed?" do
      it "can not list if email not allowed" do
        expect(Config).to receive(:allowed_vm_host_users).and_return("user2@example.com,user3@example.com")

        visit "/vm-host"

        expect(page.title).to eq("Ubicloud - Forbidden")
        expect(page.status_code).to eq(403)
        expect(page).to have_content "Forbidden"
      end

      it "can not click on sidebar if email not allowed" do
        expect(Config).to receive(:allowed_vm_host_users).and_return("user2@example.com,user3@example.com").twice

        visit "/dashboard"

        expect(page.title).to eq("Ubicloud - Dashboard")
        expect(page.status_code).to eq(200)

        expect(page).not_to have_content "VM Hosts"
        expect { find "a[href='/vm-host']" }.to raise_error Capybara::ElementNotFound
      end

      it "can list if email allowed" do
        expect(Config).to receive(:allowed_vm_host_users).and_return("user@example.com,user2@example.com").at_least(:once)

        visit "/vm-host"

        expect(page.title).to eq("Ubicloud - VM Hosts")
        expect(page).to have_content "No virtual machine host"

        click_link "New Virtual Machine Host"
        expect(page.title).to eq("Ubicloud - Add VM Host")
      end
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

      expect(page.title).to eq("Ubicloud - 127.0.0.1")
      expect(page).to have_content "Waiting for SSH keys to be created. Please refresh the page."
      expect(VmHost.count).to eq(1)
    end

    it "can show virtual machine host details" do
      vm_host.sshable.update(raw_private_key_1: SshKey.generate.keypair)
      shadow = Clover::VmHostShadow.new(vm_host)
      visit "/vm-host"

      expect(page.title).to eq("Ubicloud - VM Hosts")
      expect(page).to have_content shadow.host

      click_link "Show", href: "/vm-host/#{shadow.id}"

      expect(page.title).to eq("Ubicloud - #{shadow.host}")
      expect(page).to have_content shadow.host
      expect(page).to have_content shadow.public_keys.first
    end

    it "raises not found when virtual machine host not exists" do
      visit "/vm-host/08s56d4kaj94xsmrnf5v5m3mav"

      expect(page.title).to eq("Ubicloud - Page not found")
      expect(page.status_code).to eq(404)
      expect(page).to have_content "Page not found"
    end
  end
end
