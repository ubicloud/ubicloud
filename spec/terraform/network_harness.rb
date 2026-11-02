# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ubicloud_firewall" do
  def firewall = <<~HCL
    resource "ubicloud_firewall" "web" {
      location = "eu-central-h1"
      name     = "web"
    }
  HCL

  it "adopts the firewall by name when a proxy answers 502 after the API created it" do
    at(:response, "POST firewall/web") { it.answer(502) }
    tf.apply firewall

    expect(ledger.requests).to eq ["POST firewall/web", "GET firewall/web", "GET firewall/@web"]
    expect(Firewall.where(project_id: project.id).count).to eq 1
    expect(tf.state("ubicloud_firewall.web")["id"]).to eq Firewall.first(project_id: project.id).ubid
    expect(tf.plan).to be_empty
  end

  it "adopts the firewall that another client creates between a lost create and its resend" do
    at(:request, "POST firewall/web") { it.answer(502) }
    at(:response, "GET firewall/web") { Firewall.create(name: "web", description: "", location_id: Location::HETZNER_FSN1_ID, project_id: project.id) }
    tf.apply firewall

    expect(ledger.entries.map { [it.to_s, it.status] }).to eq [
      ["POST firewall/web", 502], ["GET firewall/web", 404], ["POST firewall/web", 400], ["GET firewall/web", 200], ["GET firewall/@web", 200],
    ]
    expect(tf.state("ubicloud_firewall.web")["id"]).to eq Firewall.first(project_id: project.id).ubid
    expect(tf.plan).to be_empty
  end

  it "fails the create, and keeps no state, when the name is taken first" do
    Firewall.create(name: "web", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)

    expect { tf.apply firewall }.to raise_error(TerraformHarness::Error, /already taken/)
    expect(ledger.requests).to eq ["POST firewall/web"]
    expect(tf.state).to be_empty
  end

  it "repeats a create refused with Retry-After before it reached the API" do
    at(:request, "POST firewall/web") { it.answer(429, nil, "retry-after" => "1") }

    expect(tf.apply(firewall).mutations).to eq ["POST firewall/web", "POST firewall/web"]
    expect(Firewall.where(project_id: project.id).count).to eq 1
  end
end

RSpec.describe "ubicloud_firewall_rule" do
  def firewall = <<~HCL
    resource "ubicloud_firewall" "web" {
      location = "eu-central-h1"
      name     = "web"
    }
  HCL

  def rule(cidr, port_range = nil) = firewall + <<~HCL
    resource "ubicloud_firewall_rule" "ssh" {
      location    = "eu-central-h1"
      firewall_id = ubicloud_firewall.web.id
      cidr        = "#{cidr}"
      #{"port_range = \"#{port_range}\"" if port_range}
    }
  HCL

  def rules = FirewallRule.where(firewall_id: Firewall.first(project_id: project.id).id)

  # The API masks the host bits and returns 22..22 as 22, but the provider
  # compares canonical forms and keeps what was written.
  it "plans no change for a CIDR with host bits and a one-port range" do
    tf.apply rule("10.0.0.5/8", "22..22")

    expect(rules.map { [it.cidr.to_s, it.port_range.to_range] }).to eq [["10.0.0.0/8", 22...23]]
    expect(tf.state("ubicloud_firewall_rule.ssh")).to include("cidr" => "10.0.0.5/8", "port_range" => "22..22")
    expect(tf.plan).to be_empty
  end

  # A firewall holds only its rules' ids, so a rule that the
  # configuration does not manage is read through the rule's datasource.
  it "reads a rule's protocol through the rule's datasource, by one of its firewall's firewall_rule_ids" do
    fw = Firewall.create(name: "web", location_id: Location::HETZNER_FSN1_ID, project_id: project.id)
    dns = fw.insert_firewall_rule("10.0.0.0/8", Sequel.pg_range(53..53), protocol: "udp")

    tf.apply <<~HCL
      data "ubicloud_firewall" "web" {
        location = "eu-central-h1"
        name     = "web"
      }

      data "ubicloud_firewall_rule" "dns" {
        location    = "eu-central-h1"
        firewall_id = data.ubicloud_firewall.web.id
        id          = one(data.ubicloud_firewall.web.firewall_rule_ids)
      }
    HCL
    expect(tf.state("data.ubicloud_firewall_rule.dns")).to include("id" => dns.ubid, "cidr" => "10.0.0.0/8", "port_range" => "53", "protocol" => "udp")
  end

  it "reports a rule whose create answer was lost, with the import to run" do
    tf.apply firewall
    at(:response, "POST firewall/@web/firewall-rule") { it.answer(502) }

    fw = Firewall.first(project_id: project.id)
    expect { tf.apply(rule("10.0.0.0/8")) }
      .to raise_error(TerraformHarness::Error, %r{with ubicloud_firewall_rule\.ssh,.*terraform import ADDRESS\s+eu-central-h1/#{fw.ubid}/ID}m)
    expect(ledger.mutations("* firewall/@web/*")).to eq ["POST firewall/@web/firewall-rule"]
    expect(rules.count).to eq 1
    expect(tf.state.keys).to eq ["ubicloud_firewall.web"]
  end
end

RSpec.describe "reported by customers" do
  it "keeps rules written as bare addresses and one-port ranges stable" do
    tf.apply <<~HCL
      terraform {
        required_version = ">= 1.6"
        required_providers {
          ubicloud = {
            source  = "ubicloud/ubicloud"
            version = "~> 1.0"
          }
        }
      }

      provider "ubicloud" {
        project_id = "pj7wzqhq4yv1j4dbj7d1z1ts8r"
      }

      locals {
        office = ["203.0.113.7", "2001:db8::7"]
        ports  = { ssh = "22..22", https = "443" }
      }

      resource "ubicloud_firewall" "edge" {
        location = "eu-central-h1"
        name     = "edge"
      }

      resource "ubicloud_firewall_rule" "office" {
        for_each    = { for p in setproduct(local.office, values(local.ports)) : "${p[0]}:${p[1]}" => p }
        location    = "eu-central-h1"
        firewall_id = ubicloud_firewall.edge.id
        cidr        = each.value[0]
        port_range  = each.value[1]
      }
    HCL

    expect(tf.plan).to be_empty
    rules = Firewall.first(project_id: project.id).firewall_rules
    expect(rules.map { it.cidr.to_s }.uniq.sort).to eq ["2001:db8::7/128", "203.0.113.7/32"]
  end
end
