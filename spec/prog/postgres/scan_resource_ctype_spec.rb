# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::ScanResourceCtype do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID) }
  let(:st) { described_class.assemble(postgres_resource.id) }
  let(:unit) { "ctype_scan_#{st.ubid}_0" }
  let(:target) { {"action" => "scan", "relation" => "users", "objects" => ["citext: users_email_key"], "query" => counts_query("email::text ~ '[^\\x01-\\x7f]'", "users")} }
  let(:empty_result) { described_class::EMPTY_RESULT }

  # Returns the sshable of the server the prog reads, loaded through the
  # prog's own resource object so the stub applies.
  def prime_sshable
    create_postgres_server(resource: postgres_resource)
    nx.server.vm.sshable
  end

  def counts_query(filter, relation)
    "SELECT 'ctype_scan_counts' AS marker, count(*) FILTER (WHERE #{filter}) AS nonascii, count(*) AS total FROM #{relation}"
  end

  def psql_cmd(dbname_arg)
    "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -d #{dbname_arg} -t --csv -v 'ON_ERROR_STOP=1'"
  end

  describe ".assemble" do
    it "creates a strand for the resource" do
      expect(st.prog).to eq("Postgres::ScanResourceCtype")
      expect(st.label).to eq("start")
      expect(st.stack[0]["subject_id"]).to eq(postgres_resource.id)
    end
  end

  describe "#before_run" do
    it "pops if the resource is gone" do
      postgres_resource.destroy
      expect { nx.before_run }.to exit({"msg" => "postgres resource is gone"})
    end

    it "pops if the resource is being destroyed" do
      postgres_resource.incr_destroying
      expect { nx.before_run }.to exit({"msg" => "postgres resource is gone"})
    end

    it "does nothing while the resource is alive" do
      expect(nx.before_run).to be_nil
    end
  end

  describe "#start" do
    it "registers a non-paging deadline, then hops" do
      expect { nx.start }.to hop("list_databases")
      expect(nx.strand.stack[0]["deadline_page"]).to be false
      expect(Time.new(nx.strand.stack[0]["deadline_at"])).to be_within(5).of(Time.now + 24 * 60 * 60)
    end
  end

  describe "#server" do
    it "skips a resource with no representative server" do
      expect { nx.server }.to exit({"msg" => "skipped", "reason" => "no representative server"})
    end

    it "reads a standby when there is one" do
      create_postgres_server(resource: postgres_resource)
      standby = create_postgres_server(resource: postgres_resource, is_representative: false)
      expect(nx.server.id).to eq(standby.id)
    end

    it "reads the primary when the only standby is still catching up" do
      primary = create_postgres_server(resource: postgres_resource)
      create_postgres_server(resource: postgres_resource, is_representative: false).update(synchronization_status: "catching_up")
      expect(nx.server.id).to eq(primary.id)
    end

    it "reads the representative server when there is no standby" do
      primary = create_postgres_server(resource: postgres_resource)
      expect(nx.server.id).to eq(primary.id)
    end
  end

  describe "#list_databases" do
    it "keeps the databases in the frame" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(psql_cmd("postgres"), stdin: described_class::DATABASES_SQL).and_return("app\npostgres\n")
      expect { nx.list_databases }.to hop("list_targets")
      expect(frame_value(nx, "databases")).to eq(["app", "postgres"])
      expect(frame_value(nx, "results")).to eq({})
      expect(frame_value(nx, "step")).to eq(0)
    end

    it "pops unreachable when no database is returned" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(psql_cmd("postgres"), stdin: described_class::DATABASES_SQL).and_return("")
      expect { nx.list_databases }.to exit({"msg" => "unreachable", "error" => "no databases returned"})
    end

    it "pops unreachable when it cannot list the databases" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(psql_cmd("postgres"), stdin: described_class::DATABASES_SQL).and_raise(Sshable::SshError.new("boom", "", "connection refused", nil, nil))
      expect { nx.list_databases }.to exit({"msg" => "unreachable", "error" => "connection refused"})
    end
  end

  describe "#list_targets" do
    before { refresh_frame(nx, new_values: {"databases" => ["app"], "results" => {}, "step" => 0}) }

    it "keeps the tables to scan and records the objects that need no scan" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(psql_cmd("dbname\\=\\'app\\'"), stdin: described_class::TARGETS_SQL).and_return(<<~CSV)
        refresh,mv,"[{""kind"": ""materialized_view"", ""object"": ""mv""}]",
        scan,users,"[{""kind"": ""citext"", ""object"": ""users_email_key""}]","#{target["query"]}"
        unresolved,parted,"[{""kind"": ""partition_key"", ""object"": ""parted""}]",
      CSV
      expect { nx.list_targets }.to hop("wait_table_scan")
      expect(frame_value(nx, "targets")).to eq([target])
      expect(frame_value(nx, "results")).to eq({"app" => empty_result.merge("refresh" => ["materialized_view: mv"], "unresolved" => ["partition_key: parted"])})
    end

    it "records a failed database and scans nothing in it" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(psql_cmd("dbname\\=\\'app\\'"), stdin: described_class::TARGETS_SQL).and_raise(Sshable::SshError.new("boom", "", "canceling statement", nil, nil))
      expect { nx.list_targets }.to hop("wait_table_scan")
      expect(frame_value(nx, "targets")).to eq([])
      expect(frame_value(nx, "results")).to eq({"app" => empty_result.merge("failed" => [{"error" => "canceling statement"}])})
    end
  end

  describe "#wait_table_scan" do
    def prime(targets:, databases: ["app"])
      refresh_frame(nx, new_values: {"databases" => databases, "results" => {"app" => empty_result}, "targets" => targets, "step" => 0})
      prime_sshable
    end

    def expect_cleanup(sshable)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean #{unit}")
    end

    # The journal tail of a finished scan: the systemd line names the query,
    # and psql prints the counts.
    def scan_log(counts)
      <<~LOG
        Oct 21 10:00:00 host systemd[1]: Started #{unit}.service - /bin/bash -c "sudo -u postgres psql -c #{target["query"]}".
        #{"Oct 21 10:00:02 host bash[1234]: ctype_scan_counts,#{counts}\n" if counts}
      LOG
    end

    def expect_log(sshable, log)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{unit}").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("sudo journalctl -u #{unit} -n 20 --no-pager").and_return(log)
    end

    it "hops to report after the last table of the last database" do
      prime(targets: [])
      expect { nx.wait_table_scan }.to hop("report")
    end

    it "hops to the next database after its last table" do
      prime(targets: [], databases: ["app", "postgres"])
      expect { nx.wait_table_scan }.to hop("list_targets")
    end

    it "starts the scan of the next table" do
      sshable = prime(targets: [target])
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{unit}").and_return("NotStarted")
      command = ["sudo", "-u", "postgres", "psql", "-U", "postgres", "-X", "-d", "dbname='app'", "-t", "--csv", "-v", "ON_ERROR_STOP=1", "-c", target["query"]]
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run #{unit} #{command.shelljoin}", stdin: nil, log: true)
      expect { nx.wait_table_scan }.to nap(5)
    end

    it "naps while the scan runs" do
      sshable = prime(targets: [target])
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{unit}").and_return("InProgress")
      expect { nx.wait_table_scan }.to nap(5)
      expect(frame_value(nx, "step")).to eq(0)
    end

    it "counts a table with only ASCII rows as safe, then moves to the next table" do
      sshable = prime(targets: [target, target])
      expect_log(sshable, scan_log("0,12"))
      expect_cleanup(sshable)
      expect { nx.wait_table_scan }.to nap(5)
      expect(frame_value(nx, "results")).to eq({"app" => empty_result.merge("safe" => 1)})
      expect(frame_value(nx, "targets")).to eq([target])
      expect(frame_value(nx, "step")).to eq(1)
    end

    it "lists a table with non-ASCII rows for a rebuild" do
      sshable = prime(targets: [target])
      expect_log(sshable, scan_log("3,12"))
      expect_cleanup(sshable)
      expect { nx.wait_table_scan }.to nap(5)
      expect(frame_value(nx, "results")).to eq({"app" => empty_result.merge("rebuild" => [{"relation" => "users", "objects" => ["citext: users_email_key"], "nonascii" => 3, "total" => 12}])})
    end

    it "reads the log again while journald has not received the counts" do
      sshable = prime(targets: [target])
      expect_log(sshable, scan_log(nil))
      expect { nx.wait_table_scan }.to nap(5)
      expect(frame_value(nx, "log_reads")).to eq(1)
      expect(frame_value(nx, "step")).to eq(0)
    end

    it "lists the scan as failed when the counts never reach the log" do
      sshable = prime(targets: [target])
      refresh_frame(nx, new_values: {"log_reads" => described_class::LOG_READ_LIMIT - 1})
      expect_log(sshable, scan_log(nil))
      expect_cleanup(sshable)
      expect { nx.wait_table_scan }.to nap(5)
      expect(frame_value(nx, "results")["app"]["failed"]).to eq([{"relation" => "users", "objects" => ["citext: users_email_key"], "error" => ["no counts in the log"] + scan_log(nil).lines.map(&:chomp)}])
      expect(frame_value(nx, "log_reads")).to eq(0)
      expect(frame_value(nx, "step")).to eq(1)
    end

    it "lists a failed scan with the end of its log" do
      sshable = prime(targets: [target])
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check #{unit}").and_return("Failed")
      expect(sshable).to receive(:_cmd).with("sudo journalctl -u #{unit} -n 20 --no-pager").and_return("ERROR: canceling statement due to conflict with recovery\n")
      expect_cleanup(sshable)
      expect { nx.wait_table_scan }.to nap(5)
      expect(frame_value(nx, "results")).to eq({"app" => empty_result.merge("failed" => [{"relation" => "users", "objects" => ["citext: users_email_key"], "error" => ["ERROR: canceling statement due to conflict with recovery"]}])})
    end
  end

  describe "#report" do
    def report_with(results)
      refresh_frame(nx, new_values: {"results" => results})
      nx.report
    end

    it "pops clean when every table is safe" do
      results = {"app" => empty_result.merge("safe" => 2, "refresh" => ["materialized_view: mv"])}
      expect { report_with(results) }.to exit({"msg" => "clean", "rebuild_databases" => [], "failed_databases" => [], "refresh_databases" => ["app"], "unresolved_databases" => [], "databases" => results})
    end

    it "pops rebuild when a table has non-ASCII rows" do
      results = {"app" => empty_result.merge("rebuild" => [{"relation" => "users"}]), "postgres" => empty_result}
      expect { report_with(results) }.to exit({"msg" => "rebuild", "rebuild_databases" => ["app"], "failed_databases" => [], "refresh_databases" => [], "unresolved_databases" => [], "databases" => results})
    end

    it "pops review when a scan failed or an object is unresolved, before rebuild" do
      results = {"app" => empty_result.merge("rebuild" => [{"relation" => "users"}], "unresolved" => ["partition_key: parted"]), "postgres" => empty_result.merge("failed" => [{"error" => "boom"}])}
      expect { report_with(results) }.to exit({"msg" => "review", "rebuild_databases" => ["app"], "failed_databases" => ["postgres"], "refresh_databases" => [], "unresolved_databases" => ["app"], "databases" => results})
    end
  end

  # Runs TARGETS_SQL in the test database, as psql runs it in a customer
  # database, and keeps the rows for the fixtures. Their columns use a libc
  # C.UTF-8 collation, so their case rules come from glibc whatever the test
  # database's own locale is. A plain tsvector column has no collation and
  # follows the database ctype, so its spec needs one that is not C or POSIX.
  describe "TARGETS_SQL" do
    before { DB.run("CREATE COLLATION scan_c_utf8 (provider = libc, locale = 'C.UTF-8')") }

    def targets
      DB.fetch(described_class::TARGETS_SQL).all.select { it[:relation].include?("scan_") }
    end

    it "resolves each kind of object to the columns it reads" do
      DB.run(<<~SQL)
        CREATE TABLE scan_t (id int PRIMARY KEY, name text COLLATE scan_c_utf8, body text COLLATE scan_c_utf8, code citext COLLATE scan_c_utf8 UNIQUE,
          unread text COLLATE scan_c_utf8, low text COLLATE scan_c_utf8 GENERATED ALWAYS AS (lower(name)) STORED, CHECK (upper(body) <> 'X'));
        CREATE INDEX scan_pred ON scan_t (id) WHERE name ILIKE 'a%';
        CREATE TABLE scan_part (region text COLLATE scan_c_utf8, other text COLLATE scan_c_utf8) PARTITION BY LIST (lower(region));
        CREATE MATERIALIZED VIEW scan_mv AS SELECT lower(name) AS l FROM scan_t;
      SQL
      expect(targets.map { it.values_at(:action, :relation, :objects) }).to eq([
        ["refresh", "scan_mv", %([{"kind": "materialized_view", "object": "scan_mv"}])],
        ["scan", "scan_part", %([{"kind": "partition_key", "object": "scan_part"}])],
        ["scan", "scan_t", %([{"kind": "check_constraint", "object": "scan_t.scan_t_body_check"}, {"kind": "citext", "object": "scan_t_code_key"}, ) +
          %({"kind": "expression", "object": "scan_pred"}, {"kind": "stored_column", "object": "scan_t.low"}])],
      ])
      expect(targets.to_h { it.values_at(:relation, :query) }.except("scan_mv")).to eq(
        "scan_part" => counts_query("region::text ~ '[^\\x01-\\x7f]'", "scan_part"),
        "scan_t" => counts_query("body::text ~ '[^\\x01-\\x7f]' OR code::text ~ '[^\\x01-\\x7f]' OR id::text ~ '[^\\x01-\\x7f]' OR low::text ~ '[^\\x01-\\x7f]' OR name::text ~ '[^\\x01-\\x7f]'", "scan_t"),
      )
    end

    it "scans every text-like column of a table with a plain tsvector column" do
      skip "a plain tsvector column follows the database ctype" if %w[C POSIX].include?(DB[:pg_database].where(datname: Sequel.function(:current_database)).get(:datctype))
      DB.run("CREATE TABLE scan_docs (n int, title text, meta jsonb, doc tsvector)")
      expect(targets.map { it.values_at(:relation, :query) }).to eq([
        ["scan_docs", counts_query("doc::text ~ '[^\\x01-\\x7f]' OR meta::text ~ '[^\\x01-\\x7f]' OR title::text ~ '[^\\x01-\\x7f]'", "scan_docs")],
      ])
    end

    it "counts the rows with a character outside ASCII" do
      DB.run(<<~SQL)
        CREATE TABLE "scan_We.ird" ("Na me" text COLLATE scan_c_utf8);
        CREATE INDEX ON "scan_We.ird" (upper("Na me"));
        INSERT INTO "scan_We.ird" VALUES ('plain'), ('Ünïcode'), ('emoji 🙂'), (NULL);
      SQL
      expect(DB.fetch(targets.first[:query].freeze).single_record.values).to eq(["ctype_scan_counts", 2, 4])
    end
  end
end
