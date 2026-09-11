# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "terraform: ubicloud_postgres" do
  before do
    # The postgres prog graph hangs internal resources off a service
    # project, exactly as the route specs stub it.
    service_project = Project.create(name: "default")
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  it "polls creating -> running, with the spec ticking the clock" do
    runner = tf_runner("postgres_basic.tf.erb", name: "tf-pg")

    # The provider's create POSTs (which assembles the strand graph but
    # runs nothing), then polls GET until state == "running". Gate the
    # first poll.
    gate = tf_gate(method: "GET", path: %r{/postgres/tf-pg\z})
    apply = tf_async { runner.run("apply", "-auto-approve", "-no-color") }

    gate.wait_for_arrival

    # POST has landed: the resource exists, assembled but never run, and
    # its API-visible state derives purely from strand rows.
    pg = PostgresResource.first(project_id: tf_project.id, name: "tf-pg")
    expect(pg.strand.label).to eq "start"
    expect(pg.display_state).to eq "creating"

    # Tick the clock: row surgery, not prog execution.
    make_pg_running!(pg)
    expect(pg.display_state).to eq "running"

    gate.release
    result = apply.value

    expect(result.status.success?).to be(true), result.stderr

    by_addr = runner.state_resources.to_h { [it["address"], it["values"]] }
    attrs = by_addr["ubicloud_postgres.db"]
    expect(attrs.values_at("name", "id", "state")).to eq ["tf-pg", pg.ubid, "running"]

    # The generated datasource, read in the same apply after the
    # released poll: state agrees, and created_at renders iso8601
    # (the date-time conversion row).
    data = by_addr["data.ubicloud_postgres.db"]
    expect(data.values_at("id", "state")).to eq [pg.ubid, "running"]
    expect(data["created_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/)
  end

  it "upgrades v0 state: the bare-era timeouts relic migrates and plans no-op" do
    runner = tf_runner("postgres_basic.tf.erb", name: "pg-v0")
    gate = tf_gate(method: "POST", path: %r{/postgres/pg-v0\z})
    apply = tf_async { runner.run("apply", "-auto-approve", "-no-color") }
    gate.wait_for_arrival
    gate.release
    pg = nil
    50.times { (pg = PostgresResource.first(project_id: tf_project.id, name: "pg-v0")) ? break : sleep(0.1) }
    make_pg_running!(pg)
    expect(apply.value.status.success?).to be true

    # Pin an observed CLI behavior: terraform 1.15.8 records instance
    # schema_version 0 even though the provider advertises 1 on the
    # wire (verified via `providers schema -json`). Version
    # negotiation still uses the advertised 1 - the upgrade RPC below
    # fires - and the identity upgrader makes the resulting permanent
    # re-upgrade free. If this expectation ever flips to 1, the CLI
    # fixed the recording and this comment can go.
    raw = JSON.parse(File.read(runner.state_path))
    inst = raw["resources"].find { it["type"] == "ubicloud_postgres" }["instances"][0]
    expect(inst["schema_version"]).to eq 0

    # Rewrite the fresh state as a bare-era relic: the attribute-less
    # timeouts object that wire type produced for an explicit empty
    # block, under schema_version 0.
    inst["attributes"]["timeouts"] = {}
    raw["serial"] += 1
    File.write(runner.state_path, JSON.generate(raw))

    # Planning under version 1 routes through UpgradeResourceState:
    # the populated type decodes the relic and the plan converges.
    actions = runner.plan_json["resource_changes"].map { it["change"]["actions"] }.flatten.uniq
    expect(actions).to eq ["no-op"]

    # A refresh-only apply persists the upgraded shape; the on-disk
    # state then round-trips through `terraform show -json`.
    runner.run!("apply", "-refresh-only", "-auto-approve", "-no-color")
    values = runner.state_resources.find { it["type"] == "ubicloud_postgres" }["values"]
    expect(values["id"]).to eq pg.ubid
    expect(values["timeouts"]).to be_nil
  end
end
