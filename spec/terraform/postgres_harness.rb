# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ubicloud_postgres" do
  def database(name: "db", version: "17", size: "standard-2", storage_size: 128, **attrs) = <<~HCL
    resource "ubicloud_postgres" "db" {
      location       = "eu-central-h1"
      name           = "#{name}"
      size           = "#{size}"
      storage_size   = #{storage_size}
      target_version = "#{version}"
      #{attrs.map { |k, v| "#{k} = #{v}" }.join("\n")}
    }
  HCL

  def db = PostgresResource.first(project_id: project.id)

  # In production a resize leaves the database needing convergence until
  # its servers are recycled in the maintenance window, and until then the
  # upgrade route refuses it. The hook puts the servers at their targets
  # after each verb, so here only the ledger shows the order.
  it "upgrades before it resizes when one apply changes both" do
    tf.apply database

    expect(tf.apply(database(version: "18", size: "standard-4")).mutations).to eq ["POST postgres/@db/upgrade", "PATCH postgres/@db"]
    expect([db.target_version, db.target_vm_size, db.version, db.vm_size]).to eq ["18", "standard-4", "18", "standard-4"]
    expect(tf.plan).to be_empty
  end

  it "upgrades twice, one version at a time" do
    tf.apply database(version: "16")

    expect(tf.apply(database(version: "17")).mutations).to eq ["POST postgres/@db/upgrade"]
    expect(tf.apply(database(version: "18")).mutations).to eq ["POST postgres/@db/upgrade"]
    expect(db.version).to eq "18"
    expect(tf.plan).to be_empty
  end

  it "changes the HA type, storage size and tags with one PATCH" do
    tf.apply database(ha_type: '"async"')
    expect(db.servers.count).to eq 2

    expect(tf.apply(database(storage_size: 256, tags: '[{key = "env", value = "prod"}]')).mutations).to eq ["PATCH postgres/@db"]
    expect([db.ha_type, db.servers.count, db.storage_size_gib, db.tags]).to eq ["none", 1, 256, [{"key" => "env", "value" => "prod"}]]
    expect(tf.plan).to be_empty
  end

  # Terraform converts the number to a string, which is how the API
  # stores and returns each value.
  it "round-trips a number in a config map as a string" do
    expect(tf.apply(database(pg_config: "{max_connections = 200}")).mutations).to eq ["POST postgres/db"]
    expect(db.user_config).to eq("max_connections" => "200")
    expect(tf.plan).to be_empty

    expect(tf.apply(database(pg_config: "{max_connections = 300}", pgbouncer_config: "{max_client_conn = 400}")).mutations).to eq ["POST postgres/@db/config"]
    expect([db.user_config, db.pgbouncer_user_config]).to eq [{"max_connections" => "300"}, {"max_client_conn" => "400"}]
    expect(tf.plan).to be_empty
  end

  # The create does not take the maintenance window. set-maintenance-window
  # also carries maintenance_window_days, which the provider sends empty; a
  # project without the flag that enables the days accepts only that.
  it "sets the maintenance window after the create on a project without the days flag" do
    expect(tf.apply(database(maintenance_window_start_at: 3)).mutations).to eq ["POST postgres/db", "POST postgres/@db/set-maintenance-window"]
    expect(db.maintenance_window_start_at).to eq 3
    expect(tf.plan).to be_empty

    expect(tf.apply(database(maintenance_window_start_at: 22)).mutations).to eq ["POST postgres/@db/set-maintenance-window"]
    expect(db.maintenance_window_start_at).to eq 22
    expect(tf.plan).to be_empty
  end

  it "replaces a database it created when restrict_by_default is added" do
    tf.apply database

    plan = tf.plan(database(restrict_by_default: true))
    expect(plan.actions).to eq("ubicloud_postgres.db" => :replace)
    expect(plan.output).to match(/restrict_by_default .* # forces replacement/)
  end

  # The API never returns restrict_by_default, so the import leaves it
  # null in state. The configured value is then adopted by an update that
  # sends nothing, rather than by replacing the database.
  it "imports a database by location and name, and plans no replacement for its restrict_by_default" do
    tf.apply database(restrict_by_default: true)
    tf.run "state", "rm", "ubicloud_postgres.db"

    plan = tf.plan <<~HCL + database(restrict_by_default: true)
      import {
        to = ubicloud_postgres.db
        id = "eu-central-h1/db"
      }
    HCL
    expect(plan.actions).to eq("ubicloud_postgres.db" => :update)
    expect(tf.apply.mutations).to be_empty
    expect(tf.state("ubicloud_postgres.db")).to include("id" => db.ubid, "restrict_by_default" => true)
    expect(tf.plan).to be_empty
  end

  it "adopts the database by name when a proxy answers 502 after the API created it" do
    at(:response, "POST postgres/db") { it.answer(502) }
    tf.apply database

    expect(PostgresResource.where(project_id: project.id).count).to eq 1
    expect(ledger.mutations).to eq ["POST postgres/db"]
    expect(ledger.requests).to include "GET postgres/db"
    expect(tf.state("ubicloud_postgres.db")["id"]).to eq db.ubid
    expect(tf.plan).to be_empty
  end

  # PostgresResourceNexus calls handle_storage_auto_scale from its wait
  # label. An auto-scale raises the database's targets but not the sizes
  # last requested, and only the latter are compared with the
  # configuration. disk_usage_percent would read the server over SSH.
  it "plans no change after a storage auto-scale" do
    tf.apply database
    pg = db

    allow(Util).to receive(:send_email)
    allow(pg.representative_server).to receive(:disk_usage_percent).and_return(91)
    pg.handle_storage_auto_scale
    settle(pg)

    expect([pg.target_storage_size_gib, pg.storage_size_gib]).to eq [256, 256]
    expect(tf.plan).to be_empty
  end
end
