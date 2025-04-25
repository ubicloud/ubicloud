# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  subject(:postgres_resource) {
    described_class.new(
      name: "pg-name",
      superuser_password: "dummy-password"
    ) { it.id = "6181ddb3-0002-8ad0-9aeb-084832c9273b" }
  }

  it "returns connection string without ubid qualifier" do
    expect(Prog::Postgres::PostgresResourceNexus).to receive(:dns_zone).and_return("something").at_least(:once)
    expect(postgres_resource).to receive(:hostname_version).and_return("v1")
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.postgres.ubicloud.com?channel_binding=require")
  end

  it "returns connection string with ubid qualifier" do
    expect(Prog::Postgres::PostgresResourceNexus).to receive(:dns_zone).and_return("something").at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.pgc60xvcr00a5kbnggj1js4kkq.postgres.ubicloud.com?channel_binding=require")
  end

  it "returns connection string with ip address if config is not set" do
    expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, vm: instance_double(Vm, ephemeral_net4: "1.2.3.4"))).at_least(:once)
    expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@1.2.3.4?channel_binding=require")
  end

  it "returns connection string as nil if there is no server" do
    expect(postgres_resource).to receive(:representative_server).and_return(nil).at_least(:once)
    expect(postgres_resource.connection_string).to be_nil
  end

  it "returns replication_connection_string" do
    s = postgres_resource.replication_connection_string(application_name: "pgubidstandby")
    expect(s).to include("ubi_replication@pgc60xvcr00a5kbnggj1js4kkq.postgres.ubicloud.com", "application_name=pgubidstandby", "sslcert=/etc/ssl/certs/server.crt")
  end

  it "returns has_enough_fresh_servers correctly" do
    expect(postgres_resource.servers).to receive(:count).and_return(1, 1)
    expect(postgres_resource).to receive(:target_server_count).and_return(1, 2)
    expect(postgres_resource.has_enough_fresh_servers?).to be(true)
    expect(postgres_resource.has_enough_fresh_servers?).to be(false)
  end

  it "returns has_enough_ready_servers correctly" do
    expect(postgres_resource.servers).to receive(:count).and_return(1, 1)
    expect(postgres_resource).to receive(:target_server_count).and_return(1, 2)
    expect(postgres_resource.has_enough_ready_servers?).to be(true)
    expect(postgres_resource.has_enough_ready_servers?).to be(false)
  end

  it "returns needs_convergence correctly" do
    expect(postgres_resource.servers).to receive(:any?).and_return(true, false, false)
    expect(postgres_resource.servers).to receive(:count).and_return(1, 2)
    expect(postgres_resource).to receive(:target_server_count).and_return(2, 2)

    expect(postgres_resource.needs_convergence?).to be(true)
    expect(postgres_resource.needs_convergence?).to be(true)
    expect(postgres_resource.needs_convergence?).to be(false)
  end

  describe "display_state" do
    it "returns 'deleting' when strand label is 'destroy'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "destroy")).at_least(:once)
      expect(postgres_resource.display_state).to eq("deleting")
    end

    it "returns 'unavailable' when representative server's strand label is 'unavailable'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(postgres_resource).to receive(:representative_server).and_return(instance_double(PostgresServer, strand: instance_double(Strand, label: "unavailable")))
      expect(postgres_resource.display_state).to eq("unavailable")
    end

    it "returns 'converging' when strand has ConvergePostgresResource children" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait", children: [instance_double(Strand, prog: "Postgres::ConvergePostgresResource")])).at_least(:once)
      expect(postgres_resource.display_state).to eq("converging")
    end

    it "returns 'running' when strand label is 'wait' and has no children" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait", children: [])).at_least(:once)
      expect(postgres_resource.display_state).to eq("running")
    end

    it "returns 'creating' when strand is 'wait_server'" do
      expect(postgres_resource).to receive(:strand).and_return(instance_double(Strand, label: "wait_server", children: [])).at_least(:once)
      expect(postgres_resource.display_state).to eq("creating")
    end
  end

  it "returns target_standby_count correctly" do
    expect(postgres_resource).to receive(:ha_type).and_return(PostgresResource::HaType::NONE, PostgresResource::HaType::ASYNC, PostgresResource::HaType::SYNC)
    (0..2).each { expect(postgres_resource.target_standby_count).to eq(it) }
  end

  it "returns target_server_count correctly" do
    expect(postgres_resource).to receive(:target_standby_count).and_return(0, 1, 2)
    (0..2).each { expect(postgres_resource.target_server_count).to eq(it + 1) }
  end

  it "sets firewall rules" do
    firewall = instance_double(Firewall, name: "#{postgres_resource.ubid}-firewall")
    expect(postgres_resource).to receive(:private_subnet).exactly(2).and_return(instance_double(PrivateSubnet, firewalls: [firewall], net4: "10.238.50.0/26", net6: "fd19:9c92:e9b9:a1a::/64")).at_least(:once)
    expect(postgres_resource).to receive(:firewall_rules).exactly(2).and_return([instance_double(PostgresFirewallRule, cidr: "0.0.0.0/0")])
    expect(firewall).to receive(:replace_firewall_rules).with([
      {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(5432..5432)},
      {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(6432..6432)},
      {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22..22)},
      {cidr: "::/0", port_range: Sequel.pg_range(22..22)},
      {cidr: "10.238.50.0/26", port_range: Sequel.pg_range(5432..5432)},
      {cidr: "10.238.50.0/26", port_range: Sequel.pg_range(6432..6432)},
      {cidr: "fd19:9c92:e9b9:a1a::/64", port_range: Sequel.pg_range(5432..5432)},
      {cidr: "fd19:9c92:e9b9:a1a::/64", port_range: Sequel.pg_range(6432..6432)}
    ])
    postgres_resource.set_firewall_rules
  end
end
