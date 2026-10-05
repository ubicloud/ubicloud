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

    it "naps while the first audit runs, then keeps its verdict and hops to migrate" do
      with_fork
      expect { nx.audit_before }.to hop("wait_audit_before")
      expect { nx.wait_audit_before }.to nap(120)
      nx.strand.children.first.update(exitval: {"msg" => "clean"}, lease: Time.now - 10)
      expect { nx.wait_audit_before }.to hop("migrate")
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

  describe "#migrate" do
    it "sets the fork's target family" do
      fork = with_fork
      expect { nx.migrate }.to hop("wait_migrated")
      expect(fork.reload.target_image_family).to eq("ubuntu-2604")
    end

    it "stops for review when the fork is gone" do
      refresh_frame(nx, new_values: {"fork_id" => PostgresResource.generate_uuid})
      expect { nx.migrate }.to hop("wait_review")
    end
  end

  describe "#wait_migrated" do
    it "naps while the fork converges, and hops once its servers run the target family" do
      fork = with_fork
      fork.update(target_image_family: "ubuntu-2604")
      expect { nx.wait_migrated }.to nap(60)
      fork.representative_server.update(image_family: "ubuntu-2604")
      expect { described_class.new(nx.strand).wait_migrated }.to hop("audit_after")
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

  describe "#report" do
    let(:clean_phase) { {"ok" => 2, "failed" => 0, "unchecked" => 0, "seconds" => 0.5, "failures" => []} }

    before do
      with_fork
      refresh_frame(nx, new_values: {"verdict_before" => {"msg" => "ctype_review", "actions" => ["scan"]}, "verdict_after" => {"msg" => "ctype_review", "actions" => ["scan"]},
                                     "results" => {"app" => {"script" => "Succeeded", "phases" => {"amcheck" => clean_phase}}}})
    end

    it "passes when both audits agree and every phase succeeded" do
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("passed")
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

    it "needs review when an audit is missing" do
      refresh_frame(nx, new_values: {"verdict_before" => nil})
      expect { nx.report }.to hop("wait_review")
      expect(frame_value(nx, "status")).to eq("review needed")
    end
  end

  # These run the script's parts in the test database; rh_shift stands in for
  # a user function that case-maps. The amcheck part needs a superuser to
  # create the extension, which the CI role is not.
  describe "script parts" do
    before do
      DB.run(<<~SQL)
        CREATE TABLE rh_cfg (flag boolean);
        INSERT INTO rh_cfg VALUES (false);
        CREATE FUNCTION rh_shift(t text) RETURNS text IMMUTABLE LANGUAGE sql
          AS $$ SELECT CASE WHEN (SELECT flag FROM public.rh_cfg) THEN 'same' ELSE lower(t) END $$;
        CREATE TABLE rh_t (id int, name text COLLATE "und-x-icu");
        CREATE UNIQUE INDEX rh_shift_idx ON rh_t (rh_shift(name));
        CREATE INDEX rh_icu_idx ON rh_t (name);
        CREATE INDEX rh_plain_idx ON rh_t (id);
        INSERT INTO rh_t (id, name) VALUES (1, 'a'), (2, 'b');
      SQL
    end

    it "lists the indexes the audit lists, with their access method" do
      expect(DB.fetch(described_class::TARGETS_SQL).all.select { it[:name].start_with?("rh_") }.sort_by { it[:name] }.map { it.values_at(:name, :amname) }).to eq([
        ["rh_icu_idx", "btree"],
        ["rh_shift_idx", "btree"],
      ])
    end
  end

  describe "#wait_review" do
    it "holds the strand for an operator" do
      expect { nx.wait_review }.to nap(60 * 60 * 24 * 365 * 1000)
    end
  end
end
