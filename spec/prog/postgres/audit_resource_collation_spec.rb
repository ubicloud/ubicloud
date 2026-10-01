# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::AuditResourceCollation do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:st) { described_class.assemble(postgres_resource.id) }

  # The details entry for a database default on en_US.utf8.
  let(:en_us_default) do
    {"collation" => "default", "provider" => "c", "locale" => "en_US.utf8", "ctype" => "en_US.utf8", "deterministic" => true, "action" => "refresh"}
  end

  # Returns the sshable the prog's representative server will use, loaded
  # through the prog's own memoized resource object so the stub applies.
  def prime_sshable
    create_postgres_server(resource: postgres_resource)
    nx.postgres_resource.representative_server.vm.sshable
  end

  # The exact command run_query issues (:user is postgres). The enumeration
  # query uses the plain "postgres" database; per-database queries pass a
  # shell-escaped conninfo value.
  def psql_cmd(dbname_arg)
    "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -d #{dbname_arg} -t --csv -v 'ON_ERROR_STOP=1'"
  end

  def cmd_for(dbname)
    psql_cmd("dbname\\=\\'#{dbname}\\'")
  end

  # Stubs the database-enumeration query. Each row is [name, allowconn, unsafe,
  # collate, ctype_at_risk, provider, ctype, icu_locale]; a row may stop after
  # ctype_at_risk, and then the default is libc with ctype equal to collate.
  def stub_databases(sshable, rows)
    rows = rows.map { (it.length == 5) ? it + ["c", it[3], ""] : it }
    expect(sshable).to receive(:_cmd).with(psql_cmd("postgres"), stdin: described_class::DATABASES_SQL).and_return(rows.map { it.join(",") }.join("\n") + "\n")
  end

  # Stubs the details query for one database. Each row is [kind, name,
  # collation, provider, locale, ctype, deterministic, unique, size_bytes].
  def stub_details(sshable, dbname, rows = [])
    expect(sshable).to receive(:_cmd).with(cmd_for(dbname), stdin: described_class::DETAILS_SQL).and_return(rows.map { it.join(",") }.join("\n") + "\n")
  end

  # Stubs the case-mapping query for one database. Each row is [kind, object, source].
  def stub_ctype(sshable, dbname, rows = [])
    expect(sshable).to receive(:_cmd).with(cmd_for(dbname), stdin: described_class::CTYPE_SQL).and_return(rows.map { it.join(",") }.join("\n") + "\n")
  end

  # Runs the labels from enumerate to report, as the strand would, and returns
  # the result of report.
  def run_audit
    expect { nx.enumerate }.to hop("audit_details")
    count = nx.databases.size
    count.times do |i|
      expect { nx.audit_details }.to hop("audit_ctype")
      expect { nx.audit_ctype }.to hop((i == count - 1) ? "report" : "audit_details")
    end
    nx.report
  end

  describe ".assemble" do
    it "creates a strand for the resource" do
      expect(st.prog).to eq("Postgres::AuditResourceCollation")
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
      expect { nx.start }.to hop("enumerate")
      expect(nx.strand.stack[0]["deadline_page"]).to be false
      expect(Time.new(nx.strand.stack[0]["deadline_at"])).to be_within(5).of(Time.now + 15 * 60)
    end
  end

  describe "#enumerate" do
    it "skips a resource with no representative server" do
      expect { nx.enumerate }.to exit({"msg" => "skipped", "reason" => "no representative server"})
    end

    it "pops unreachable with the error when it cannot enumerate databases" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(psql_cmd("postgres"), stdin: described_class::DATABASES_SQL).and_raise(Sshable::SshError.new("boom", "", "connection refused", nil, nil))
      expect { nx.enumerate }.to exit({"msg" => "unreachable", "error" => "connection refused"})
      expect(Page.active).to be_empty
    end

    it "pops unreachable when enumeration returns no databases" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(psql_cmd("postgres"), stdin: described_class::DATABASES_SQL).and_return("")
      expect { nx.enumerate }.to exit({"msg" => "unreachable", "error" => "no databases returned"})
    end

    it "keeps the databases in the frame and extends the deadline by their count" do
      sshable = prime_sshable
      stub_databases(sshable, [["appdb", "t", "f", "C.UTF-8", "t"], ["postgres", "t", "f", "C.UTF-8", "t"]])
      expect { nx.enumerate }.to hop("audit_details")
      expect(nx.databases.map { it["name"] }).to eq(["appdb", "postgres"])
      expect(nx.results).to eq([])
      expect(nx.strand.stack[0]["deadline_page"]).to be false
      expect(Time.new(nx.strand.stack[0]["deadline_at"])).to be_within(5).of(Time.now + 9 * 60)
    end
  end

  describe "#audit_details and #audit_ctype" do
    it "adds one result per database, one query per label run" do
      sshable = prime_sshable
      stub_databases(sshable, [["appdb", "t", "f", "C.UTF-8", "t"]])
      stub_details(sshable, "appdb")
      stub_ctype(sshable, "appdb")
      expect { nx.enumerate }.to hop("audit_details")
      expect { nx.audit_details }.to hop("audit_ctype")
      expect(nx.results).to eq([{"name" => "appdb", "connectable" => true, "flagged" => false, "details_verified" => true}])
      expect { nx.audit_ctype }.to hop("report")
      expect(nx.results).to eq([{"name" => "appdb", "connectable" => true, "flagged" => false, "details_verified" => true,
                                 "ctype_verified" => true, "ctype_objects" => [], "ctype_object_count" => 0, "ctype_sources" => {}}])
    end
  end

  describe "a full run" do
    it "pops clean and creates no page when every database uses only verified collations" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "f", "C.UTF-8", "t"], ["template0", "f", "f", "C.UTF-8", "t"]])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "clean"})
      expect(Page.active).to be_empty
    end

    it "lists the flagged database when a non-default database uses a non-verified collation" do
      sshable = prime_sshable
      stub_databases(sshable, [["appdb", "t", "f", "C.UTF-8", "t"], ["postgres", "t", "f", "C.UTF-8", "t"]])
      stub_ctype(sshable, "appdb")
      stub_details(sshable, "appdb", [
        ["collation", "natural_sort", "natural_sort", "i", "en-u-kn", "", "t", "", ""],
        ["index", "tags_name_lower_key", "natural_sort", "", "", "", "", "t", "16384"],
        ["column", "\"\"\"Tag\"\".name\"", "natural_sort", "", "", "", "", "", ""],
        ["object", "constraint tags_name_check on table tags", "natural_sort", "", "", "", "", "", ""],
      ])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => ["appdb"], "unverified_databases" => [], "ctype_databases" => {},
        "details" => {"appdb" => {
          "collations" => [{"collation" => "natural_sort", "provider" => "i", "locale" => "en-u-kn", "ctype" => nil, "deterministic" => true, "action" => "reindex"}],
          "objects" => [
            {"kind" => "index", "object" => "tags_name_lower_key", "collation" => "natural_sort", "action" => "reindex", "unique" => true, "size_bytes" => 16384},
            {"kind" => "column", "object" => "\"Tag\".name", "collation" => "natural_sort", "action" => "reindex"},
            {"kind" => "object", "object" => "constraint tags_name_check on table tags", "collation" => "natural_sort", "action" => "reindex"},
          ],
          "object_total" => 3,
        }},
        "database_totals" => {"flagged" => 1, "unverified" => 0, "ctype" => 0}, "actions" => ["reindex"]})
      expect(Page.active).to be_empty
    end

    it "lists a non-connectable database whose default collation is not verified" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "f", "C.UTF-8", "t"], ["template0", "f", "t", "en_US.UTF-8", "t"]])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => ["template0"], "unverified_databases" => [], "ctype_databases" => {},
        "details" => {"template0" => {"collations" => [en_us_default.merge("locale" => "en_US.UTF-8", "ctype" => "en_US.UTF-8")], "objects" => [], "object_total" => 0}},
        "database_totals" => {"flagged" => 1, "unverified" => 0, "ctype" => 0}, "actions" => ["refresh"]})
    end

    it "lists a database it cannot query as unverified" do
      sshable = prime_sshable
      stub_databases(sshable, [["lockeddb", "t", "f", "C.UTF-8", "f"], ["postgres", "t", "f", "C.UTF-8", "f"]])
      expect(sshable).to receive(:_cmd).with(cmd_for("lockeddb"), stdin: described_class::DETAILS_SQL).and_raise(Sshable::SshError.new("boom", "", "permission denied", nil, nil))
      stub_ctype(sshable, "lockeddb")
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => [], "unverified_databases" => ["lockeddb"], "ctype_databases" => {}, "details" => {}, "database_totals" => {"flagged" => 0, "unverified" => 1, "ctype" => 0}, "actions" => ["review"]})
    end

    it "runs the case-mapping query where the database ctype is not at risk, as an explicit collation can be" do
      sshable = prime_sshable
      stub_databases(sshable, [["builtindb", "t", "f", "C.UTF-8", "f"], ["postgres", "t", "f", "C", "f"]])
      stub_details(sshable, "builtindb")
      stub_ctype(sshable, "builtindb", [["expression", "names_lower_idx", "icu"]])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "ctype_review", "ctype_databases" => {
        "builtindb" => {"objects" => [{"kind" => "expression", "object" => "names_lower_idx", "source" => "icu"}], "total" => 1, "sources" => {"icu" => 1}},
      }, "database_totals" => {"flagged" => 0, "unverified" => 0, "ctype" => 1}, "actions" => ["reindex"]})
    end

    it "does not list a non-connectable database whose own ctype is not at risk" do
      sshable = prime_sshable
      stub_databases(sshable, [["closeddb", "f", "f", "C", "f"], ["postgres", "t", "f", "C.UTF-8", "t"]])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "clean"})
    end

    it "pops ctype_review with the object names when only case-mapping objects are found" do
      sshable = prime_sshable
      stub_databases(sshable, [["appdb", "t", "f", "C.UTF8", "t"], ["postgres", "t", "f", "C.UTF-8", "t"]])
      stub_details(sshable, "appdb")
      stub_ctype(sshable, "appdb", [["citext", "users_email_key", "glibc"], ["expression", "tags_lower_idx", "icu"], ["pg_trgm", "public.users_name_trgm_idx", "glibc"]])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "ctype_review", "ctype_databases" => {
        "appdb" => {
          "objects" => [
            {"kind" => "citext", "object" => "users_email_key", "source" => "glibc"},
            {"kind" => "expression", "object" => "tags_lower_idx", "source" => "icu"},
            {"kind" => "pg_trgm", "object" => "public.users_name_trgm_idx", "source" => "glibc"},
          ],
          "total" => 3,
          "sources" => {"glibc" => 2, "icu" => 1},
        },
      }, "database_totals" => {"flagged" => 0, "unverified" => 0, "ctype" => 1}, "actions" => ["reindex", "scan"]})
      expect(Page.active).to be_empty
    end

    it "includes case-mapping objects in a flagged verdict" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "t", "en_US.utf8", "t"]])
      stub_ctype(sshable, "postgres", [["expression", "users_lower_idx", "glibc"]])
      stub_details(sshable, "postgres", [["index", "users_name_idx", "default", "", "", "", "", "f", "8192"]])
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => ["postgres"], "unverified_databases" => [],
        "ctype_databases" => {"postgres" => {"objects" => [{"kind" => "expression", "object" => "users_lower_idx", "source" => "glibc"}], "total" => 1, "sources" => {"glibc" => 1}}},
        "details" => {"postgres" => {"collations" => [en_us_default], "objects" => [], "object_total" => 0}},
        "database_totals" => {"flagged" => 1, "unverified" => 0, "ctype" => 1}, "actions" => ["scan", "refresh"]})
    end

    it "caps the object names per database but keeps the total" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "f", "C.UTF-8", "t"]])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres", Array.new(60) { ["expression", "idx_#{it}", "glibc"] })
      objects = Array.new(described_class::OBJECT_LIMIT) { {"kind" => "expression", "object" => "idx_#{it}", "source" => "glibc"} }
      expect { run_audit }.to exit({"msg" => "ctype_review", "ctype_databases" => {"postgres" => {"objects" => objects, "total" => 60, "sources" => {"glibc" => 60}}}, "database_totals" => {"flagged" => 0, "unverified" => 0, "ctype" => 1}, "actions" => ["scan"]})
    end

    it "lists a database as unverified when the case-mapping query fails" do
      sshable = prime_sshable
      stub_databases(sshable, [["appdb", "t", "f", "C.UTF-8", "t"]])
      stub_details(sshable, "appdb")
      expect(sshable).to receive(:_cmd).with(cmd_for("appdb"), stdin: described_class::CTYPE_SQL).and_raise(Sshable::SshError.new("boom", "", "canceling statement", nil, nil))
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => [], "unverified_databases" => ["appdb"], "ctype_databases" => {}, "details" => {}, "database_totals" => {"flagged" => 0, "unverified" => 1, "ctype" => 0}, "actions" => ["review"]})
    end

    it "lists a non-connectable at-risk database other than template0 as unverified" do
      sshable = prime_sshable
      stub_databases(sshable, [["closeddb", "f", "f", "C.UTF-8", "t"], ["postgres", "t", "f", "C.UTF-8", "t"], ["template0", "f", "f", "C.UTF-8", "t"]])
      stub_details(sshable, "postgres")
      stub_ctype(sshable, "postgres")
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => [], "unverified_databases" => ["closeddb"], "ctype_databases" => {}, "details" => {}, "database_totals" => {"flagged" => 0, "unverified" => 1, "ctype" => 0}, "actions" => ["review"]})
    end

    it "blocks the move when a flagged libc collation names a locale the target image lacks" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "f", "C.UTF8", "t"]])
      stub_ctype(sshable, "postgres")
      stub_details(sshable, "postgres", [
        ["collation", "de_DE.utf8", "de_DE.utf8", "c", "de_DE.utf8", "de_DE.utf8", "t", "", ""],
        ["collation", "en_US", "en_US", "c", "en_US.utf8", "en_US.utf8", "t", "", ""],
        ["index", "names_de_idx", "de_DE.utf8", "", "", "", "", "f", "16384"],
        ["index", "names_en_idx", "en_US", "", "", "", "", "f", "8192"],
      ])
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => ["postgres"], "unverified_databases" => [], "ctype_databases" => {},
        "details" => {"postgres" => {
          "collations" => [
            {"collation" => "de_DE.utf8", "provider" => "c", "locale" => "de_DE.utf8", "ctype" => "de_DE.utf8", "deterministic" => true, "action" => "blocker"},
            {"collation" => "en_US", "provider" => "c", "locale" => "en_US.utf8", "ctype" => "en_US.utf8", "deterministic" => true, "action" => "refresh"},
          ],
          "objects" => [{"kind" => "index", "object" => "names_de_idx", "collation" => "de_DE.utf8", "action" => "blocker", "unique" => false, "size_bytes" => 16384}],
          "object_total" => 1,
        }},
        "database_totals" => {"flagged" => 1, "unverified" => 0, "ctype" => 0}, "actions" => ["blocker", "refresh"]})
    end

    it "reindexes an ICU database default and lists the indexes on it" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "t", "en_US.utf8", "t", "i", "en_US.utf8", "und-u-ks-level2"]])
      stub_ctype(sshable, "postgres")
      stub_details(sshable, "postgres", [["index", "users_email_key", "default", "", "", "", "", "t", "8192"]])
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => ["postgres"], "unverified_databases" => [], "ctype_databases" => {},
        "details" => {"postgres" => {
          "collations" => [{"collation" => "default", "provider" => "i", "locale" => "und-u-ks-level2", "ctype" => "en_US.utf8", "deterministic" => true, "action" => "reindex"}],
          "objects" => [{"kind" => "index", "object" => "users_email_key", "collation" => "default", "action" => "reindex", "unique" => true, "size_bytes" => 8192}],
          "object_total" => 1,
        }},
        "database_totals" => {"flagged" => 1, "unverified" => 0, "ctype" => 0}, "actions" => ["reindex"]})
    end

    it "lists a flagged database as unverified when the details query fails, keeping its default" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "t", "en_US.utf8", "t"]])
      stub_ctype(sshable, "postgres")
      expect(sshable).to receive(:_cmd).with(cmd_for("postgres"), stdin: described_class::DETAILS_SQL).and_raise(Sshable::SshError.new("boom", "", "canceling statement", nil, nil))
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => ["postgres"], "unverified_databases" => ["postgres"], "ctype_databases" => {},
        "details" => {"postgres" => {"collations" => [en_us_default], "objects" => [], "object_total" => 0}},
        "database_totals" => {"flagged" => 1, "unverified" => 1, "ctype" => 0}, "actions" => ["review", "refresh"]})
    end

    it "keeps a blocker default when the details query fails" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "t", "de_DE.utf8", "t"]])
      stub_ctype(sshable, "postgres")
      expect(sshable).to receive(:_cmd).with(cmd_for("postgres"), stdin: described_class::DETAILS_SQL).and_raise(Sshable::SshError.new("boom", "", "canceling statement", nil, nil))
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => ["postgres"], "unverified_databases" => ["postgres"], "ctype_databases" => {},
        "details" => {"postgres" => {"collations" => [en_us_default.merge("locale" => "de_DE.utf8", "ctype" => "de_DE.utf8", "action" => "blocker")], "objects" => [], "object_total" => 0}},
        "database_totals" => {"flagged" => 1, "unverified" => 1, "ctype" => 0}, "actions" => ["blocker", "review"]})
    end

    it "caps the databases named in the verdict but keeps the totals" do
      sshable = prime_sshable
      names = Array.new(25) { format("db%02d", it) }
      stub_databases(sshable, names.map { [it, "f", "t", "en_US.utf8", "f"] })
      details = names.first(described_class::DATABASE_LIMIT).to_h { [it, {"collations" => [en_us_default], "objects" => [], "object_total" => 0}] }
      expect { run_audit }.to exit({"msg" => "flagged", "flagged_databases" => names.first(described_class::DATABASE_LIMIT), "unverified_databases" => [], "ctype_databases" => {},
        "details" => details, "database_totals" => {"flagged" => 25, "unverified" => 0, "ctype" => 0}, "actions" => ["refresh"]})
    end
  end

  # The SQL specs run each query in the test database, as psql runs it in a
  # customer database, and keep the rows that name a fixture object. The
  # fixtures use ICU and libc C.* collations, which every Postgres build has.
  def audit_rows(sql, key)
    DB.fetch(sql).all.select { it[key].include?("audit_") }
  end

  describe "DETAILS_SQL" do
    it "lists a column on an ICU collation, and leaves out libc C, C.* and builtin ones" do
      DB.run("CREATE COLLATION audit_c_utf8 (provider = libc, locale = 'C.UTF-8')")
      DB.run(%(CREATE TABLE audit_t (icu text COLLATE "und-x-icu", cu text COLLATE audit_c_utf8, c text COLLATE "C", p text COLLATE "POSIX")))
      expect(audit_rows(described_class::DETAILS_SQL, :name).map { it.values_at(:kind, :name, :collname) }).to eq([["column", "audit_t.icu", "und-x-icu"]])
    end

    it "finds an ICU collation named only inside an expression or by a type, once per partitioned table" do
      DB.run(<<~SQL)
        CREATE TABLE audit_t (id int, name text, g bool GENERATED ALWAYS AS (name COLLATE "und-x-icu" < 'm') STORED);
        CREATE INDEX audit_pred ON audit_t (id) WHERE name COLLATE "und-x-icu" > 'm';
        ALTER TABLE audit_t ADD CONSTRAINT audit_check CHECK (name COLLATE "und-x-icu" > 'a');
        CREATE TABLE audit_part (name text) PARTITION BY RANGE (name COLLATE "und-x-icu");
        CREATE TABLE audit_part_a PARTITION OF audit_part FOR VALUES FROM ('a') TO ('m');
        CREATE TYPE audit_range AS RANGE (subtype = text, collation = "und-x-icu");
      SQL
      expect(audit_rows(described_class::DETAILS_SQL, :name).map { it.values_at(:kind, :name, :collname) }).to eq([
        ["index", "audit_pred", "und-x-icu"],
        ["object", "constraint audit_check on table audit_t", "und-x-icu"],
        ["object", "default value for column g of table audit_t", "und-x-icu"],
        ["object", "table audit_part", "und-x-icu"],
        ["object", "type audit_range", "und-x-icu"],
      ])
    end
  end

  describe "CTYPE_SQL" do
    it "takes the case rules from the columns an object reads, not only from its keys" do
      DB.run(<<~SQL)
        CREATE TABLE audit_t (id int, name text COLLATE "und-x-icu", g text GENERATED ALWAYS AS (lower(name)) STORED);
        CREATE INDEX audit_bool ON audit_t ((lower(name) = 'x'));
        CREATE INDEX audit_pred ON audit_t (id) WHERE lower(name) = 'x';
      SQL
      expect(audit_rows(described_class::CTYPE_SQL, :object).map(&:values)).to eq([
        ["expression", "audit_bool", "icu"],
        ["expression", "audit_pred", "icu"],
        ["stored_column", "audit_t.g", "icu"],
      ])
    end

    it "lists case-insensitive matching, regex classes, user functions, check constraints, partition keys, and materialized views" do
      DB.run(<<~SQL)
        CREATE FUNCTION audit_norm(t text) RETURNS text LANGUAGE sql IMMUTABLE AS 'SELECT lower(t)';
        CREATE TABLE audit_t (id int, e text COLLATE "und-x-icu" CHECK (e = lower(e)));
        CREATE INDEX audit_udf ON audit_t (audit_norm(e));
        CREATE INDEX audit_ilike ON audit_t (id) WHERE e ILIKE 'a%';
        CREATE INDEX audit_class ON audit_t (id) WHERE e ~ '^[[:upper:]]';
        CREATE INDEX audit_plain ON audit_t (e);
        CREATE TABLE audit_part (region text COLLATE "und-x-icu") PARTITION BY LIST (lower(region));
        CREATE MATERIALIZED VIEW audit_mv AS SELECT lower(e) AS le FROM audit_t;
      SQL
      expect(audit_rows(described_class::CTYPE_SQL, :object).map(&:values)).to eq([
        ["check_constraint", "audit_t.audit_t_e_check", "icu"],
        ["expression", "audit_class", "icu"],
        ["expression", "audit_ilike", "icu"],
        ["expression", "audit_udf", "icu"],
        ["materialized_view", "audit_mv", "icu"],
        ["partition_key", "audit_part", "icu"],
      ])
    end

    it "finds citext through arrays, nested domains, and casts" do
      DB.run(<<~SQL)
        CREATE DOMAIN audit_d1 AS citext;
        CREATE DOMAIN audit_d2 AS audit_d1;
        CREATE TABLE audit_t (a citext[] COLLATE "und-x-icu", d audit_d2 COLLATE "und-x-icu", e text COLLATE "und-x-icu");
        CREATE INDEX audit_array ON audit_t USING gin (a);
        CREATE UNIQUE INDEX audit_domain ON audit_t (d);
        CREATE INDEX audit_cast ON audit_t ((e::citext));
        CREATE INDEX audit_text ON audit_t (e);
      SQL
      expect(audit_rows(described_class::CTYPE_SQL, :object).map(&:values)).to eq([
        ["citext", "audit_array", "icu"],
        ["citext", "audit_cast", "icu"],
        ["citext", "audit_domain", "icu"],
      ])
    end
  end

  describe "#parse_databases" do
    it "maps each row to a typed database hash" do
      output = "postgres,t,f,C.UTF-8,t,c,C.UTF-8,\ntemplate0,f,t,en_US.utf8,f,i,en_US.utf8,und\n"
      expect(nx.parse_databases(output)).to eq([
        {"name" => "postgres", "connectable" => true, "default_unsafe" => false, "default_collation" => "C.UTF-8", "ctype_at_risk" => true, "provider" => "c", "ctype" => "C.UTF-8", "icu_locale" => nil},
        {"name" => "template0", "connectable" => false, "default_unsafe" => true, "default_collation" => "en_US.utf8", "ctype_at_risk" => false, "provider" => "i", "ctype" => "en_US.utf8", "icu_locale" => "und"},
      ])
    end

    it "returns an empty array for empty output" do
      expect(nx.parse_databases("")).to eq([])
    end
  end

  describe "#conninfo" do
    it "quotes the name and escapes backslashes and single quotes" do
      expect(nx.conninfo("appdb")).to eq("dbname='appdb'")
      expect(nx.conninfo("it's=a\\b")).to eq("dbname='it\\'s=a\\\\b'")
    end
  end

  describe "#normalize_locale" do
    it "lowercases the codeset and drops its dashes, as locale -a prints it" do
      expect(nx.normalize_locale("en_US.UTF-8")).to eq("en_US.utf8")
      expect(nx.normalize_locale("C.UTF8")).to eq("C.utf8")
      expect(nx.normalize_locale("POSIX")).to eq("POSIX")
    end
  end
end
