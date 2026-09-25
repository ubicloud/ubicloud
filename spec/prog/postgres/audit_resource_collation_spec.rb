# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::AuditResourceCollation do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:st) { described_class.assemble(postgres_resource.id) }

  # A clean database: default C.UTF-8, no explicit or inherited flagged collations.
  let(:clean_row) { "f,C.UTF-8,c,0,0,0,0,0," }
  # A flagged database: en_US.utf8 default, one explicit column/index/domain, and
  # inherited objects, with the in-use flagged collations pipe-joined.
  let(:flagged_row) { "t,en_US.utf8,c,1,1,1,3,2,en-US-x-icu|en_US.utf8|fr-FR-x-icu|und-x-icu" }

  # Returns the sshable the prog's representative server will use, primed on the
  # prog's own memoized resource object so the stub actually applies.
  def prime_sshable
    create_postgres_server(resource: postgres_resource)
    rep = nx.postgres_resource.representative_server
    rep.vm.associations[:sshable] = rep.vm.sshable
    rep.vm.sshable
  end

  # The exact command run_query issues against a database (:user is postgres).
  def cmd_for(dbname)
    "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -d #{dbname} -t --csv -v 'ON_ERROR_STOP=1'"
  end

  # Stubs the database-enumeration query. Each row is [name, allowconn, unsafe, collate].
  def stub_databases(sshable, rows)
    expect(sshable).to receive(:_cmd).with(cmd_for("postgres"), stdin: described_class::DATABASES_SQL).and_return(rows.map { it.join(",") }.join("\n") + "\n")
  end

  # Stubs the per-database audit query for one database.
  def stub_audit(sshable, dbname, row)
    expect(sshable).to receive(:_cmd).with(cmd_for(dbname), stdin: described_class::AUDIT_SQL).and_return("#{row}\n")
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
      expect { nx.before_run }.not_to exit({"msg" => "postgres resource is gone"})
    end
  end

  describe "#start" do
    it "registers a non-paging deadline, then hops" do
      expect { nx.start }.to hop("audit")
      expect(nx.strand.stack[0]["deadline_page"]).to be false
      expect(Time.new(nx.strand.stack[0]["deadline_at"])).to be_within(60).of(Time.now + 15 * 60)
    end
  end

  describe "#audit" do
    it "skips a resource with no representative server" do
      expect { nx.audit }.to exit({"msg" => "skipped", "reason" => "no representative server"})
    end

    it "pops clean and creates no page when every database uses only verified collations" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "f", "C.UTF-8"], ["template0", "f", "f", "C.UTF-8"]])
      stub_audit(sshable, "postgres", clean_row)
      expect { nx.audit }.to exit({"msg" => "clean"})
      expect(Page.active).to be_empty
    end

    it "lists the flagged database when a non-default database uses a non-verified collation" do
      sshable = prime_sshable
      stub_databases(sshable, [["appdb", "t", "f", "C.UTF-8"], ["postgres", "t", "f", "C.UTF-8"]])
      stub_audit(sshable, "appdb", flagged_row)
      stub_audit(sshable, "postgres", clean_row)
      expect { nx.audit }.to exit({"msg" => "flagged", "flagged_databases" => ["appdb"], "unverified_databases" => []})
      expect(Page.active).to be_empty
    end

    it "lists a non-connectable database whose default collation is not verified" do
      sshable = prime_sshable
      stub_databases(sshable, [["postgres", "t", "f", "C.UTF-8"], ["template0", "f", "t", "en_US.utf8"]])
      stub_audit(sshable, "postgres", clean_row)
      expect { nx.audit }.to exit({"msg" => "flagged", "flagged_databases" => ["template0"], "unverified_databases" => []})
    end

    it "lists a database it cannot query as unverified" do
      sshable = prime_sshable
      stub_databases(sshable, [["lockeddb", "t", "f", "C.UTF-8"], ["postgres", "t", "f", "C.UTF-8"]])
      expect(sshable).to receive(:_cmd).with(cmd_for("lockeddb"), stdin: described_class::AUDIT_SQL).and_raise(Sshable::SshError.new("boom", "", "permission denied", nil, nil))
      stub_audit(sshable, "postgres", clean_row)
      expect { nx.audit }.to exit({"msg" => "flagged", "flagged_databases" => [], "unverified_databases" => ["lockeddb"]})
    end

    it "pops unreachable with the error when it cannot enumerate databases" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(cmd_for("postgres"), stdin: described_class::DATABASES_SQL).and_raise(Sshable::SshError.new("boom", "", "connection refused", nil, nil))
      expect { nx.audit }.to exit({"msg" => "unreachable", "error" => "connection refused"})
      expect(Page.active).to be_empty
    end

    it "pops unreachable when enumeration returns no databases" do
      sshable = prime_sshable
      expect(sshable).to receive(:_cmd).with(cmd_for("postgres"), stdin: described_class::DATABASES_SQL).and_return("")
      expect { nx.audit }.to exit({"msg" => "unreachable", "error" => "no databases returned"})
    end
  end

  describe "#parse_databases" do
    it "maps each row to a typed database hash" do
      output = "postgres,t,f,C.UTF-8\ntemplate0,f,t,en_US.utf8\n"
      expect(nx.parse_databases(output)).to eq([
        {name: "postgres", connectable: true, default_unsafe: false, default_collation: "C.UTF-8"},
        {name: "template0", connectable: false, default_unsafe: true, default_collation: "en_US.utf8"},
      ])
    end

    it "returns an empty array for empty output" do
      expect(nx.parse_databases("")).to eq([])
    end
  end

  describe "#parse_result" do
    it "parses a clean row" do
      expect(nx.parse_result(clean_row)).to eq({
        default_flagged: false, default_collation: "C.UTF-8", default_provider: "c",
        explicit_columns: 0, explicit_indexes: 0, explicit_domains: 0,
        inherited_columns: 0, inherited_indexes: 0, flagged_collations: [],
      })
    end

    it "parses a flagged row with a pipe-joined collation list" do
      result = nx.parse_result(flagged_row)
      expect(result[:default_flagged]).to be true
      expect(result[:explicit_columns]).to eq(1)
      expect(result[:inherited_columns]).to eq(3)
      expect(result[:flagged_collations]).to eq(["en-US-x-icu", "en_US.utf8", "fr-FR-x-icu", "und-x-icu"])
    end
  end
end
