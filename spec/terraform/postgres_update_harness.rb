# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "terraform: postgres update verbs (generated)" do
  before do
    postgres_project = Project.create(name: "default")
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  it "dispatches patch then rename, addressing the new name only at the end" do
    tf_project.set_ff_postgres_enable_maintenance_window_days(true)
    runner = tf_runner("postgres_update.tf.erb", name: "pg-old", storage: 128)

    create_gate = tf_gate(method: "GET", path: %r{/postgres/pg-old\z})
    apply = tf_async { runner.apply }
    create_gate.wait_for_arrival
    pg = PostgresResource.first(project_id: tf_project.id, name: "pg-old")
    make_pg_running!(pg)
    create_gate.release
    apply.value

    # Second apply is the update: storage change (patch verb) + rename.
    runner.rewrite(endpoint: TerraformHarness.endpoint, token: tf_token,
      project_ubid: tf_project.ubid, location: TerraformHarness::LOCATION,
      name: "pg-new", storage: 256, mw_start: 3, mw_days: %w[mon fri])

    patch_gate = tf_gate(method: "PATCH", path: %r{/postgres/pg-old\z})
    mw_gate = tf_gate(method: "POST", path: %r{/postgres/pg-old/set-maintenance-window\z})
    rename_gate = tf_gate(method: "POST", path: %r{/postgres/pg-old/rename\z})
    final_gate = tf_gate(method: "GET", path: %r{/postgres/pg-new\z})

    update = tf_async { runner.apply }

    patch_gate.wait_for_arrival
    # Ordering: patch first; rename hasn't been attempted.
    expect(pg.reload.name).to eq "pg-old"
    patch_gate.release

    # Declared order: maintenance window fires after patch, before
    # rename; at its barrier the columns still hold defaults.
    mw_gate.wait_for_arrival
    expect(pg.reload.maintenance_window_start_at).to be_nil
    mw_gate.release

    rename_gate.wait_for_arrival
    # Patch landed (target recorded); rename still pending, so the row
    # keeps the old name. The spec ticks storage to its target - the
    # strand's job in production, the clock's job here.
    expect(pg.reload.target_storage_size_gib).to eq 256
    expect(pg.name).to eq "pg-old"
    pg.representative_server.vm.vm_storage_volumes.reject(&:boot).first
      .update(size_gib: 256)
    rename_gate.release

    # The final re-read addresses the NEW name: rename ordering and
    # persist-name recovery are both load-bearing for this to arrive.
    final_gate.wait_for_arrival.release
    update.value

    expect(pg.reload.name).to eq "pg-new"
    attrs = runner.state_resources.find { it["address"] == "ubicloud_postgres.db" }["values"]
    expect(attrs.values_at("name", "storage_size")).to eq ["pg-new", 256]
    expect(attrs["maintenance_window_days"]).to eq %w[mon fri]
    expect(pg.reload.maintenance_window_start_at).to eq 3
    expect(pg.maintenance_window_days_bitmask).to be_positive
  end

  it "config merge sends plan values plus tombstones for abandoned server keys" do
    runner = tf_runner("postgres_update.tf.erb", name: "pg-cfg", storage: 128)

    create_gate = tf_gate(method: "GET", path: %r{/postgres/pg-cfg\z})
    apply = tf_async { runner.apply }
    create_gate.wait_for_arrival
    pg = PostgresResource.first(project_id: tf_project.id, name: "pg-cfg")
    make_pg_running!(pg)
    create_gate.release
    apply.value

    # Server-side config drifts out of band before the update.
    pg.update(user_config: {"work_mem" => "64MB", "max_connections" => "100"})

    runner.rewrite(endpoint: TerraformHarness.endpoint, token: tf_token,
      project_ubid: tf_project.ubid, location: TerraformHarness::LOCATION,
      name: "pg-cfg", storage: 128, pg_config: {"max_connections" => "200", "statement_timeout" => "5000"})

    merge_gate = tf_gate(method: "PATCH", path: %r{/postgres/pg-cfg/config\z})
    update = tf_async { runner.apply }

    merge_gate.wait_for_arrival
    # The pre-read happened; the merge hasn't: server union untouched.
    expect(pg.reload.user_config).to eq("work_mem" => "64MB", "max_connections" => "100")
    merge_gate.release
    update.value

    # Merge semantics: max_connections overwritten, statement_timeout added, work_mem tombstoned away.
    expect(pg.reload.user_config).to eq("max_connections" => "200", "statement_timeout" => "5000")
    attrs = runner.state_resources.find { it["address"] == "ubicloud_postgres.db" }["values"]
    expect(attrs["pg_config"]).to eq("max_connections" => "200", "statement_timeout" => "5000")
  end

  def running_pg(name, extra = {})
    runner = tf_runner("postgres_update.tf.erb", name:, storage: 128, **extra)
    gate = tf_gate(method: "GET", path: %r{/postgres/#{name}\z})
    apply = tf_async { runner.apply }
    gate.wait_for_arrival
    pg = PostgresResource.first(project_id: tf_project.id, name:)
    make_pg_running!(pg)
    # Convergence gate for later verbs: the server's volume-derived
    # storage must match target (assemble leaves it behind).
    pg.representative_server.vm.vm_storage_volumes.reject(&:boot).first
      &.update(size_gib: pg.target_storage_size_gib)
    gate.release
    apply.value
    [runner, pg]
  end

  it "refuses to combine a version upgrade with other changes" do
    runner, pg = running_pg("pg-x", pg_version: "17")

    runner.rewrite(endpoint: TerraformHarness.endpoint, token: tf_token,
      project_ubid: tf_project.ubid, location: TerraformHarness::LOCATION,
      name: "pg-x", storage: 256, pg_version: "18")

    result = runner.run("apply", "-auto-approve", "-no-color")
    expect(result.status.success?).to be false
    expect(result.output).to include "cannot combine with other changes"
    expect(pg.reload.target_version).to eq pg.version
  end

  it "runs an exclusive upgrade: status check, dispatch, version wait" do
    runner, pg = running_pg("pg-up", pg_version: "17")

    runner.rewrite(endpoint: TerraformHarness.endpoint, token: tf_token,
      project_ubid: tf_project.ubid, location: TerraformHarness::LOCATION,
      name: "pg-up", storage: 128, pg_version: "18")

    upgrade_gate = tf_gate(method: "POST", path: %r{/postgres/pg-up/upgrade\z})
    update = tf_async { runner.apply }

    upgrade_gate.wait_for_arrival
    # The status pre-check passed (400: not upgrading) and the POST is
    # held; nothing dispatched yet.
    expect(pg.reload.target_version).to eq pg.version
    upgrade_gate.release

    # The route bumps target_version; the wait loop is now polling for
    # version 18. Tick the clock: converge version to target.
    sleep 0.1 until pg.reload.target_version == "18"
    pg.representative_server.update(version: "18")
    update.value

    attrs = runner.state_resources.find { it["address"] == "ubicloud_postgres.db" }["values"]
    expect(attrs["version"]).to eq "18"
  end

  it "reconciles an ambiguous create: bodyless 200, salvaged by name, converged" do
    runner = tf_runner("postgres_update.tf.erb", name: "pg-adopt", storage: 128)

    create_gate = tf_gate(method: "POST", path: %r{/postgres/pg-adopt\z})
    apply = tf_async {
      begin
        runner.apply
      rescue
        $!
      end
    }
    create_gate.wait_for_arrival
    # Release corrupted: the route commits the row, the client sees an
    # empty 200 - the ambiguous case. The name is the claim; the
    # provider reconciles via the details GET and proceeds into the
    # normal convergence wait, which the spec satisfies by playing the
    # control plane.
    create_gate.release(corrupt: :empty_body)

    pg = nil
    50.times do
      pg = PostgresResource.first(project_id: tf_project.id, name: "pg-adopt")
      break if pg
      sleep 0.1
    end
    expect(pg).not_to be_nil
    make_pg_running!(pg)

    result = apply.value
    expect(result).not_to be_a(Exception), -> { result.message }

    attrs = runner.state_resources.find { it["address"] == "ubicloud_postgres.db" }["values"]
    expect(attrs["id"]).to eq pg.ubid
    expect(attrs["state"]).to eq "running"

    # Converged: the reconciled create is a clean success, so the next
    # plan is a no-op - no taint, no replacement, no duplicate.
    actions = runner.plan_json["resource_changes"].map { it["change"]["actions"] }.flatten.uniq
    expect(actions).to eq ["no-op"]
  end

  it "pins stable computeds in update plans" do
    runner, pg = running_pg("pg-pin")

    runner.rewrite(endpoint: TerraformHarness.endpoint, token: tf_token,
      project_ubid: tf_project.ubid, location: TerraformHarness::LOCATION,
      name: "pg-pin", storage: 256)

    plan = runner.plan_json
    change = plan["resource_changes"].find { it["address"] == "ubicloud_postgres.db" }["change"]
    expect(change["after_unknown"]["id"]).to be_nil
    expect(change["after"]["id"]).to eq pg.ubid
    expect(change["after"]["created_at"]).to eq change["before"]["created_at"]
  end
end
