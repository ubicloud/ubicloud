# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::RehearseImageFamilyMigration do
  subject(:nx) { described_class.new(st) }

  let(:customer) { Project.create(name: "customer") }
  let(:internal) { Project.create(name: "internal") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:parent) { running_resource(customer) }
  let(:st) { described_class.assemble(parent.id, project_id: internal.id) }

  # A resource that is running on ubuntu-2204, with a backup to restore from.
  def running_resource(project)
    pg = create_postgres_resource(project:, location_id:)
    server = create_postgres_server(resource: pg)
    pg.strand.update(label: "wait")
    server.strand.update(label: "wait")
    server.timeline.update(cached_earliest_backup_at: Time.now - 60 * 60)
    pg
  end

  def with_fork
    fork = running_resource(internal)
    fork.update(name: "collation-fork-#{parent.ubid}", parent_id: parent.id, restore_target: Time.now - 5 * 60)
    refresh_frame(nx, new_values: {"fork_id" => fork.id})
    fork
  end

  def converge_strand(fork, label: "wait_reindex_decision", **)
    Strand.create(parent_id: fork.strand.id, prog: "Postgres::ConvergePostgresResource", label:, stack: [{"subject_id" => fork.id}], **)
  end

  def fork_sshable
    nx.fork.representative_server.vm.sshable
  end

  def psql(dbname)
    "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -d #{dbname} -t --csv -v 'ON_ERROR_STOP=1'"
  end

  describe ".assemble" do
    it "creates a strand for the resource with the internal project and target family" do
      expect(st.label).to eq("start")
      expect(st.stack[0]).to eq({"subject_id" => parent.id, "project_id" => internal.id, "target_image_family" => "ubuntu-2604"})
    end

    it "fails without an existing project" do
      expect { described_class.assemble(parent.id, project_id: Project.generate_uuid) }.to raise_error(RuntimeError, "No existing project")
    end

    it "fails for an unknown image family" do
      expect { described_class.assemble(parent.id, project_id: internal.id, target_image_family: "ubuntu-1804") }.to raise_error(RuntimeError, "Unknown image family")
    end
  end

  describe "#start" do
    it "registers a non-paging deadline for the review, then hops" do
      expect { nx.start }.to hop("create_fork")
      expect(nx.strand.stack[0]["deadline_target"]).to eq("wait_review")
      expect(nx.strand.stack[0]["deadline_page"]).to be false
      expect(nx.strand.stack[0]["deadline_message"]).to eq("finish the rehearsal")
    end
  end

  describe "#create_fork" do
    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(Project.create(name: "postgres-service").id)
    end

    it "forks the resource into the internal project, without public firewall rules or the init script" do
      PostgresInitScript.create_with_id(parent, init_script: "echo customer")
      expect { nx.create_fork }.to hop("wait_fork")
      fork = PostgresResource[frame_value(nx, "fork_id")]
      expect(fork.values.slice(:project_id, :parent_id, :name, :target_image_family, :target_version)).to eq(
        {project_id: internal.id, parent_id: parent.id, name: "collation-fork-#{parent.ubid}", target_image_family: "ubuntu-2204", target_version: parent.version},
      )
      expect(fork.restore_target).to be_within(5).of(Time.now - 5 * 60)
      expect(Firewall.first(project_id: internal.id, name: "#{fork.ubid}-firewall").firewall_rules).to eq([])
      expect(PostgresInitScript[fork.id]).to be_nil
    end

    it "stops for review when the resource is gone" do
      gone = described_class.new(described_class.assemble(PostgresResource.generate_uuid, project_id: internal.id))
      expect { gone.create_fork }.to hop("wait_review")
      expect(frame_value(gone, "status")).to eq("postgres resource is gone")
    end

    it "stops for review when the location belongs to a project" do
      parent.location.update(project_id: customer.id)
      expect { nx.create_fork }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("location belongs to a project, so the fork would run in that account")
    end

    it "stops for review when the resource is not running" do
      parent.strand.update(label: "start")
      expect { nx.create_fork }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("postgres resource is not running")
    end

    it "stops for review when the resource already runs the target family" do
      parent.representative_server.update(image_family: "ubuntu-2604")
      expect { nx.create_fork }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("postgres resource already runs ubuntu-2604")
    end

    it "stops for review when a fork of the resource already exists" do
      create_postgres_resource(project: internal, location_id:).update(name: "collation-fork-#{parent.ubid}")
      expect { nx.create_fork }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("fork collation-fork-#{parent.ubid} already exists")
    end

    it "stops for review when the restore target is outside the backup window" do
      parent.timeline.update(cached_earliest_backup_at: Time.now + 60 * 60)
      expect { nx.create_fork }.to hop("wait_review")
      expect(frame_value(nx, "status")).to start_with("fork failed: Validation failed for following fields: restore_target")
    end
  end

  describe "#wait_fork" do
    it "stops for review when the fork is gone" do
      refresh_frame(nx, new_values: {"fork_id" => PostgresResource.generate_uuid})
      expect { nx.wait_fork }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("fork is gone")
    end

    it "naps until the fork is running" do
      with_fork.strand.update(label: "start")
      expect { nx.wait_fork }.to nap(30)
    end

    it "hops to the first audit when the fork is running" do
      with_fork
      expect { nx.wait_fork }.to hop("audit_before")
    end
  end

  describe "audits" do
    it "buds the collation audit on the fork before the migration" do
      fork = with_fork
      expect { nx.audit_before }.to hop("wait_audit_before")
      expect(nx.strand.children.map { [it.prog, it.stack[0]["subject_id"]] }).to eq([["Postgres::AuditResourceCollation", fork.id]])
    end

    it "naps while the first audit runs, then keeps its verdict and hops to the scan" do
      with_fork
      expect { nx.audit_before }.to hop("wait_audit_before")
      expect { nx.wait_audit_before }.to nap(120)
      nx.strand.children.first.update(exitval: {"msg" => "clean"}, lease: Time.now - 10)
      expect { nx.wait_audit_before }.to hop("scan")
      expect(frame_value(nx, "verdict_before")).to eq({"msg" => "clean"})
      expect(nx.strand.children_dataset.count).to eq(0)
    end

    it "buds the second audit after the migration, and keeps its verdict" do
      with_fork
      expect { nx.audit_after }.to hop("wait_audit_after")
      nx.strand.children.first.update(exitval: {"msg" => "ctype_review", "actions" => ["scan"]}, lease: Time.now - 10)
      expect { nx.wait_audit_after }.to hop("list_databases")
      expect(frame_value(nx, "verdict_after")).to eq({"msg" => "ctype_review", "actions" => ["scan"]})
    end
  end

  describe "scan" do
    it "buds a scan of every table of the fork, then keeps its verdict and hops to migrate" do
      fork = with_fork
      expect { nx.scan }.to hop("wait_scan")
      expect(nx.strand.children.map { [it.prog, it.stack[0]] }).to eq([["Postgres::ScanResourceCtype", {"subject_id" => fork.id, "max_table_gib" => nil}]])
      expect { nx.wait_scan }.to nap(60)
      nx.strand.children.first.update(exitval: {"msg" => "clean", "reindex_jobs" => {"app" => ["SELECT 1"]}}, lease: Time.now - 10)
      expect { nx.wait_scan }.to hop("migrate")
      expect(frame_value(nx, "scan_verdict")).to eq({"msg" => "clean", "reindex_jobs" => {"app" => ["SELECT 1"]}})
    end
  end

  describe "#migrate" do
    it "sets the fork's target family" do
      fork = with_fork
      refresh_frame(nx, new_values: {"scan_verdict" => {"msg" => "clean", "reindex_jobs" => {}}})
      expect { nx.migrate }.to hop("wait_converge")
      expect(fork.reload.target_image_family).to eq("ubuntu-2604")
      expect(frame_value(nx, "old_primary_id")).to eq(fork.representative_server.id)
    end

    it "stops for review when the scan has no jobs" do
      fork = with_fork
      refresh_frame(nx, new_values: {"scan_verdict" => {"msg" => "unreachable"}})
      expect { nx.migrate }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("scan has no reindex jobs: unreachable")
      expect(fork.reload.target_image_family).to eq("ubuntu-2204")
    end

    it "stops for review when the fork is gone" do
      refresh_frame(nx, new_values: {"fork_id" => PostgresResource.generate_uuid})
      expect { nx.migrate }.to hop("wait_review")
    end
  end

  describe "#wait_converge" do
    let(:jobs) { {"app" => ["REINDEX INDEX users_email_key"]} }

    before { refresh_frame(nx, new_values: {"scan_verdict" => {"msg" => "rebuild", "reindex_jobs" => jobs}}) }

    it "writes the jobs into the frame of the fork's converge at its gate, and wakes it" do
      converge = converge_strand(with_fork, schedule: Time.now + 60)
      expect { nx.wait_converge }.to hop("wait_migrated")
      converge.reload
      expect(Prog::Postgres::ConvergePostgresResource.new(converge).reindex_jobs).to eq(jobs)
      expect(converge.stack[0]["subject_id"]).to eq(nx.fork.id)
      expect(converge.schedule).to be <= Time.now
    end

    it "naps while the converge has not reached its gate, or runs" do
      fork = with_fork
      expect { nx.wait_converge }.to nap(30)
      converge = converge_strand(fork, label: "wait_servers_to_be_ready")
      expect { nx.wait_converge }.to nap(30)
      converge.update(label: "wait_reindex_decision", lease: Time.now + 60)
      expect { nx.wait_converge }.to nap(30)
      expect(converge.reload.stack[0]).not_to have_key("reindex_jobs")
    end

    it "stops for review when the fork is gone" do
      refresh_frame(nx, new_values: {"fork_id" => PostgresResource.generate_uuid})
      expect { nx.wait_converge }.to hop("wait_review")
    end
  end

  describe "#wait_migrated" do
    let(:jobs) { {"app" => ["REINDEX INDEX a"], "shop" => ["REINDEX INDEX s"]} }

    def migrating_fork
      fork = with_fork
      fork.update(target_image_family: "ubuntu-2604")
      refresh_frame(nx, new_values: {"old_primary_id" => fork.representative_server.id, "scan_verdict" => {"msg" => "rebuild", "reindex_jobs" => jobs}})
      fork
    end

    # Each look is a new prog, so the fork and its servers are read again.
    def look
      expect { described_class.new(nx.strand).wait_migrated }.to nap(5)
      frame_value(nx, "window")
    end

    it "naps while the fork converges, and hops once the converge exits and its servers run the target family" do
      fork = migrating_fork
      fork.representative_server.update(image_family: "ubuntu-2604")
      converge = converge_strand(fork, label: "reindex")
      look
      converge.update(exitval: {"msg" => "postgres resource is converged"})
      expect { described_class.new(nx.strand).wait_migrated }.to hop("audit_after")
    end

    it "naps while the fork still runs the old family, and records nothing before the fence" do
      migrating_fork
      expect(look).to eq({})
    end

    it "records when it first sees the fence, the promote, each database's reindex, and the release" do
      fork = migrating_fork
      old = fork.representative_server
      converge = converge_strand(fork, label: "recycle_representative_server")
      expect(look).to eq({})
      old.strand.update(label: "fence")
      fenced = look
      expect(fenced.keys).to eq(["fenced"])
      old.strand.update(label: "wait_in_fence")
      expect(look).to eq(fenced)

      old.update(is_representative: false)
      create_postgres_server(resource: fork).update(image_family: "ubuntu-2604")
      converge.update(label: "prune_servers")
      promoted = look
      expect(promoted).to eq(fenced.merge("promoted" => promoted["promoted"]))
      converge.update(label: "reindex", stack: [converge.stack[0].merge("reindex_step" => 0)])
      expect(look["reindex"].size).to eq(1)
      converge.update(stack: [converge.stack[0].merge("reindex_step" => 1)])
      expect(look["reindex"].size).to eq(2)
      converge.update(label: "wait_lockout_release")
      expect(look["reindex"].size).to eq(3)
      expect(look).not_to have_key("released")

      converge.update(exitval: {"msg" => "postgres resource is converged"})
      window = look
      expect(window["released"]).to be_within(5).of(Time.now.to_i)
      expect(window["reindex"]).to eq(window["reindex"].sort)
    end

    it "gives a part it missed between two looks the time of the next" do
      fork = migrating_fork
      fork.representative_server.update(is_representative: false)
      create_postgres_server(resource: fork).update(image_family: "ubuntu-2604")
      window = look
      expect(window.keys).to eq(["fenced", "promoted", "reindex", "released"])
      expect(window.values.flatten.uniq.size).to eq(1)
      expect(window["reindex"].size).to eq(3)
    end

    it "stops for review when the reindex failed" do
      fork = with_fork
      Prog::PageNexus.assemble("reindex failed", ["PostgresReindexFailed", fork.id], fork.ubid, resource_id: fork.id)
      expect { nx.wait_migrated }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("reindex failed")
    end

    it "stops for review when the fork is gone" do
      refresh_frame(nx, new_values: {"fork_id" => PostgresResource.generate_uuid})
      expect { nx.wait_migrated }.to hop("wait_review")
    end
  end

  describe "#list_databases" do
    it "keeps the fork's connectable databases in the frame" do
      with_fork
      expect(fork_sshable).to receive(:_cmd).with(psql("postgres"), stdin: described_class::DATABASES_SQL).and_return("app\npostgres\n")
      expect { nx.list_databases }.to hop("wait_database_script")
      expect(frame_value(nx, "databases")).to eq(["app", "postgres"])
      expect(frame_value(nx, "step")).to eq(0)
      expect(frame_value(nx, "results")).to eq({})
    end
  end

  describe "#wait_database_script" do
    let(:unit_run) { "common/bin/daemonizer2 run collation_rehearsal_0 sudo -u postgres psql -U postgres -X -d dbname\\=\\'app\\'" }

    before do
      with_fork
      refresh_frame(nx, new_values: {"databases" => ["app"], "step" => 0, "results" => {}})
    end

    it "starts the script in the next database" do
      expect(fork_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check collation_rehearsal_0").and_return("NotStarted")
      expect(fork_sshable).to receive(:_cmd).with(unit_run, {log: true, stdin: described_class::SCRIPT})
      expect { nx.wait_database_script }.to nap(5)
    end

    it "naps while the script runs" do
      expect(fork_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check collation_rehearsal_0").and_return("InProgress")
      expect { nx.wait_database_script }.to nap(5)
      expect(frame_value(nx, "step")).to eq(0)
    end

    it "records each phase's results when the script succeeds, then moves to the next database" do
      expect(fork_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check collation_rehearsal_0").and_return("Succeeded")
      expect(fork_sshable).to receive(:_cmd).with(psql("dbname\\=\\'app\\'"), stdin: described_class::RESULTS_SQL).and_return(<<~CSV)
        amcheck,idx_trgm,,gin index: amcheck checks btree only,0.0
        amcheck,accounts_email_index,t,,0.4
        reindex,accounts_email_index,t,,1.2
        reindex,users_lower_name,f,,0.3
      CSV
      expect(fork_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean collation_rehearsal_0")
      expect { nx.wait_database_script }.to nap(5)
      expect(frame_value(nx, "step")).to eq(1)
      expect(frame_value(nx, "results")).to eq({"app" => {"script" => "Succeeded", "phases" => {
        "amcheck" => {"ok" => 1, "failed" => 0, "unchecked" => 1, "seconds" => 0.4, "failures" => []},
        "reindex" => {"ok" => 1, "failed" => 1, "unchecked" => 0, "seconds" => 1.5, "failures" => [{"object" => "users_lower_name", "detail" => nil}]},
      }}})
    end

    it "keeps the log when the script fails, and the error when the results cannot be read" do
      expect(fork_sshable).to receive(:_cmd).with("common/bin/daemonizer2 check collation_rehearsal_0").and_return("Failed")
      expect(fork_sshable).to receive(:_cmd).with("sudo journalctl -u collation_rehearsal_0 -n 20 --no-pager").and_return("psql: error: connection failed\n")
      expect(fork_sshable).to receive(:_cmd).with(psql("dbname\\=\\'app\\'"), stdin: described_class::RESULTS_SQL)
        .and_raise(Sshable::SshError.new("psql", "", "ERROR:  relation \"ubi_collation_rehearsal.result\" does not exist\n", 1, nil))
      expect(fork_sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean collation_rehearsal_0")
      expect { nx.wait_database_script }.to nap(5)
      expect(frame_value(nx, "results")).to eq({"app" => {"script" => "Failed", "log" => ["psql: error: connection failed"],
                                                          "phases" => {}, "results_error" => "ERROR:  relation \"ubi_collation_rehearsal.result\" does not exist"}})
    end

    it "hops to the report after the last database" do
      refresh_frame(nx, new_values: {"step" => 1})
      expect { nx.wait_database_script }.to hop("report")
    end
  end

  describe "#downtime_seconds" do
    it "gives the total and each part, from the times in the window" do
      refresh_frame(nx, new_values: {"scan_verdict" => {"reindex_jobs" => {"app" => [], "shop" => []}},
                                     "window" => {"fenced" => 100, "promoted" => 130, "reindex" => [140, 200, 260], "released" => 275}})
      expect(nx.downtime_seconds).to eq({"total" => 175, "failover" => 30, "reindex" => 120, "databases" => {"app" => 60, "shop" => 60}, "precision" => 5})
    end

    it "is nil before the lockout is released" do
      expect(nx.downtime_seconds).to be_nil
      refresh_frame(nx, new_values: {"window" => {"fenced" => 100}})
      expect(nx.downtime_seconds).to be_nil
    end
  end

  describe "#report" do
    let(:clean_phase) { {"ok" => 2, "failed" => 0, "unchecked" => 0, "seconds" => 0.5, "failures" => []} }

    before do
      with_fork
      refresh_frame(nx, new_values: {"verdict_before" => {"msg" => "ctype_review", "actions" => ["scan"]}, "verdict_after" => {"msg" => "ctype_review", "actions" => ["scan"]},
                                     "scan_verdict" => {"msg" => "rebuild", "by_hand" => [], "reindex_jobs" => {"app" => ["REINDEX INDEX i"]}},
                                     "results" => {"app" => {"script" => "Succeeded", "phases" => {"amcheck" => clean_phase}}}})
    end

    it "passes when both audits agree and every phase succeeded, and keeps the downtime" do
      refresh_frame(nx, new_values: {"window" => {"fenced" => 100, "promoted" => 110, "reindex" => [120, 150], "released" => 160}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("passed")
      expect(frame_value(nx, "downtime")).to eq({"total" => 60, "failover" => 10, "reindex" => 30, "databases" => {"app" => 30}, "precision" => 5})
    end

    it "needs review when a phase failed" do
      refresh_frame(nx, new_values: {"results" => {"app" => {"script" => "Succeeded", "phases" => {"amcheck" => clean_phase.merge("failed" => 1)}}}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when a script failed" do
      refresh_frame(nx, new_values: {"results" => {"app" => {"script" => "Failed", "phases" => {}}}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when the audits differ" do
      refresh_frame(nx, new_values: {"verdict_after" => {"msg" => "clean"}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when the audit after the migration was skipped" do
      refresh_frame(nx, new_values: {"verdict_before" => {"msg" => "skipped"}, "verdict_after" => {"msg" => "skipped"}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when the audit asks for a blocker or a manual review" do
      refresh_frame(nx, new_values: {"verdict_before" => {"msg" => "flagged", "actions" => ["blocker"]}, "verdict_after" => {"msg" => "flagged", "actions" => ["blocker"]}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when the scan could not scan a table or resolve an object" do
      refresh_frame(nx, new_values: {"scan_verdict" => {"msg" => "review", "by_hand" => []}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when the scan lists objects for work by hand" do
      refresh_frame(nx, new_values: {"scan_verdict" => {"msg" => "rebuild", "by_hand" => ["app: stored_column: t.c"]}})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when the scan is missing" do
      refresh_frame(nx, new_values: {"scan_verdict" => nil})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end

    it "needs review when an audit is missing" do
      refresh_frame(nx, new_values: {"verdict_before" => nil})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end
  end

  # These run the script's parts in the test database. A function that falsely
  # claims IMMUTABLE stands in for a library change: flipping rh_cfg makes
  # it return a different value for rows already stored. The amcheck part
  # needs a superuser to create the extension, which the CI role is not.
  describe "script parts" do
    before do
      DB.run(<<~SQL)
        CREATE TABLE rh_cfg (flag boolean);
        INSERT INTO rh_cfg VALUES (false);
        CREATE FUNCTION rh_shift(t text) RETURNS text IMMUTABLE LANGUAGE sql
          AS $$ SELECT CASE WHEN (SELECT flag FROM public.rh_cfg) THEN 'same' ELSE lower(t) END $$;
        CREATE TABLE rh_t (id int, name text COLLATE "und-x-icu", g text GENERATED ALWAYS AS (rh_shift(name)) STORED,
          CONSTRAINT rh_check CHECK (rh_shift(name) = lower(name)));
        CREATE UNIQUE INDEX rh_shift_idx ON rh_t (rh_shift(name));
        CREATE INDEX rh_icu_idx ON rh_t (name);
        CREATE INDEX rh_plain_idx ON rh_t (id);
        CREATE TABLE rh_part (region text) PARTITION BY LIST (rh_shift(region));
        CREATE TABLE rh_part_eu PARTITION OF rh_part FOR VALUES IN ('eu');
        INSERT INTO rh_t (id, name) VALUES (1, 'a'), (2, 'b');
        INSERT INTO rh_part VALUES ('EU');
      SQL
    end

    def results(phase)
      DB[Sequel[:ubi_collation_rehearsal][:result]].where(phase:).where(Sequel.like(:object, "rh\\_%")).order(:object).select_map([:object, :ok, :detail])
    end

    it "lists the indexes the audit lists, with their access method" do
      expect(DB.fetch(described_class::TARGETS_SQL).all.select { it[:name].start_with?("rh_") }.sort_by { it[:name] }.map { it.values_at(:name, :amname) }).to eq([
        ["rh_icu_idx", "btree"],
        ["rh_shift_idx", "btree"],
      ])
    end

    it "records the row checks as passing before the library changes" do
      DB.run(described_class::SETUP_SQL)
      DB.run(described_class::ROW_CHECKS_SQL)
      expect([results("check_constraint"), results("generated_column"), results("partition_bound")]).to eq([
        [["rh_t.rh_check", true, nil]], [["rh_t.g", true, nil]], [["rh_part_eu", true, nil]],
      ])
    end

    it "counts the rows each check finds stale after the library changes" do
      DB.run(described_class::SETUP_SQL)
      DB.run("UPDATE rh_cfg SET flag = true")
      DB.run(described_class::ROW_CHECKS_SQL)
      expect([results("check_constraint"), results("generated_column"), results("partition_bound")]).to eq([
        [["rh_t.rh_check", false, "2 rows do not match"]], [["rh_t.g", false, "2 rows do not match"]], [["rh_part_eu", false, "1 rows do not match"]],
      ])
    end

    it "records each collation version, and one that the library no longer gives as failed" do
      DB.run("CREATE COLLATION rh_old (provider = icu, locale = 'und', version = '0')")
      actual = DB.get(Sequel.function(:pg_collation_actual_version, Sequel.cast("rh_old", :regcollation)))
      DB.run(described_class::SETUP_SQL)
      DB.run(described_class::VERSIONS_SQL)
      rows = DB[Sequel[:ubi_collation_rehearsal][:result]].where(phase: "version").select_map([:object, :ok, :detail])
      stale, current = rows.partition { it[0] == "collation rh_old" }
      expect(stale).to eq([["collation rh_old", false, "0 recorded, #{actual} in the library"]])
      expect(current.map { it.drop(1) }.uniq).to eq([[true, nil]])
      expect(current.map(&:first)).to include("collation \"und-x-icu\"")
    end
  end

  describe "#wait_review" do
    it "holds the strand for an operator" do
      expect { nx.wait_review }.to nap(60 * 60 * 24 * 365 * 1000)
    end
  end
end
