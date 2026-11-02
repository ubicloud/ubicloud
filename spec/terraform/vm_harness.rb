# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ubicloud_vm" do
  let(:key) { "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOT0eJ0n8m0KpQ alice@example.com" }

  def vm(name: "web", public_key: key, **attrs) = <<~HCL
    resource "ubicloud_vm" "web" {
      location   = "eu-central-h1"
      name       = "#{name}"
      public_key = "#{public_key}"
      #{attrs.map { |k, v| "#{k} = #{JSON.generate(v)}" }.join("\n")}
    }
  HCL

  def web = Vm.first(project_id: project.id)

  # The API never returns public_key, so an import leaves it null in state.
  # The configured value is then adopted by an update that sends nothing,
  # rather than by replacing the VM.
  it "imports a VM by location and name, and plans no replacement for its public_key" do
    tf.apply vm
    tf.run "state", "rm", "ubicloud_vm.web"

    plan = tf.plan <<~HCL + vm
      import {
        to = ubicloud_vm.web
        id = "eu-central-h1/web"
      }
    HCL
    expect(plan.actions).to eq("ubicloud_vm.web" => :update)
    expect(tf.apply.mutations).to be_empty
    expect(tf.state("ubicloud_vm.web")).to include("id" => web.ubid, "public_key" => key)
    expect(tf.plan).to be_empty
  end

  # A VM holds only its firewalls' ids, and a firewall datasource looked
  # up by one of them holds only its rules' ids.
  it "lists its firewalls by id, and a ubicloud_firewall datasource their rules' ids" do
    tf.apply vm + <<~HCL
      data "ubicloud_firewall" "web" {
        location = "eu-central-h1"
        id       = one(ubicloud_vm.web.firewall_ids)
      }
    HCL
    firewall = web.firewalls.first

    expect(tf.state("ubicloud_vm.web")["firewall_ids"]).to eq [firewall.ubid]
    expect(firewall.firewall_rules).not_to be_empty
    expect(tf.state("data.ubicloud_firewall.web")["firewall_rule_ids"]).to match_array firewall.firewall_rules.map(&:ubid)
    expect(tf.plan).to be_empty
  end

  # A stopped VM is not pending, so the provider reads it once after the
  # rename.
  it "renames a stopped VM, and reads it once" do
    tf.apply vm
    web.strand.update(label: "stopped")

    expect(tf.apply(vm(name: "web-2"), "-refresh=false").requests).to eq ["POST vm/@web/rename", "GET vm/@web-2"]
    expect(web.name).to eq "web-2"
    expect(tf.state("ubicloud_vm.web")["state"]).to eq "stopped"
  end

  # The create does not take maintenance_window_start_at, so the provider
  # sends set-maintenance-window after it.
  it "sets the maintenance window right after the create, and changes it in place" do
    expect(tf.apply(vm(maintenance_window_start_at: 3)).mutations).to eq ["POST vm/web", "POST vm/@web/set-maintenance-window"]
    expect(web.maintenance_window_start_at).to eq 3

    expect(tf.apply(vm(maintenance_window_start_at: 22)).mutations).to eq ["POST vm/@web/set-maintenance-window"]
    expect(web.maintenance_window_start_at).to eq 22
    expect(tf.plan).to be_empty
  end

  it "clears the maintenance window when the configuration leaves it out" do
    tf.apply vm(maintenance_window_start_at: 3)

    expect(tf.apply(vm).mutations).to eq ["POST vm/@web/set-maintenance-window"]
    expect(web.maintenance_window_start_at).to be_nil
    expect(tf.state("ubicloud_vm.web")["maintenance_window_start_at"]).to be_nil
    expect(tf.plan).to be_empty
  end

  it "ends the create with an error when the API reports no capacity available" do
    allow(TerraformHarness::Settle).to receive(:settle_vm) do |vm|
      vm.incr_waiting_for_capacity
      vm.update(created_at: Time.now - 16 * 60)
    end

    expect { tf.apply vm }.to raise_error(TerraformHarness::Error, /Error creating ubicloud_vm.*its state is "no capacity available"/m)
  end

  it "keeps the VM in state, tainted, when the create outlives timeouts.create" do
    allow(TerraformHarness::Settle).to receive(:settle_vm)

    # Unless clover is loaded eagerly, the first VM create in a process
    # loads the code it runs, which can take longer than the one second
    # allowed below. Send one first and roll it back, so that the
    # provider's POST is quick and it is the wait for the VM to settle
    # that times out.
    path = "/project/#{project.ubid}/location/eu-central-h1/vm/web"
    DB.transaction(savepoint: true, rollback: :always) do
      post path, {public_key: key}.to_json, "HTTP_HOST" => "api.ubicloud.com", "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to eq 200
    end

    slow = <<~HCL
      resource "ubicloud_vm" "web" {
        location   = "eu-central-h1"
        name       = "web"
        public_key = "#{key}"
        timeouts {
          create = "1s"
        }
      }
    HCL

    expect { tf.apply slow }.to raise_error(TerraformHarness::Error, /its state was last "creating".*raise timeouts\.create/m)
    expect(tf.state("ubicloud_vm.web")["id"]).to eq web.ubid
    expect(tf.plan.actions).to eq("ubicloud_vm.web" => :replace)
  end
end
