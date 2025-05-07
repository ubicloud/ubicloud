# frozen_string_literal: true

RSpec.describe "Database" do
  it "has no unexpectedly collated columns" do
    collated_columns = DB[:pg_class]
      .join(:pg_namespace, oid: :relnamespace) { |j| Sequel.qualify(j, :nspname) !~ ["pg_catalog", "information_schema"] }
      .join(:pg_attribute, attrelid: Sequel[:pg_class][:oid])
      .join(:pg_collation, oid: :attcollation) { |j| Sequel.qualify(j, :collcollate) !~ "C" }
      .select_map(Sequel.join(%i[nspname relname attname].map { Sequel.function(:quote_ident, it) }, ".").as(:name))

    expect(collated_columns).to eq []
  end

  describe "audit_log table" do
    def insert_row(at)
      DB[:audit_log].returning(:ubid_type).insert(at:, ubid_type: "vm", action: "create", project_id: Project.generate_uuid, subject_id: Account.generate_uuid, object_ids: Sequel.pg_array([], :uuid))
    end

    it "inserts row for current date without error" do
      expect(insert_row(Date.today)).to eq [{ubid_type: "vm"}]
    end

    it "needs new partitions (action required)" do
      # if this test starts to fail, it's time to create new partitions for table audit_log. if this is ignored,
      # DB[:audit_log].insert will start to fail in 45 days or less.
      expect(insert_row(Time.now + 60 * 60 * 24 * 45)).to eq [{ubid_type: "vm"}]
    end

    it "fails to create in the past" do
      expect { insert_row(Date.new(2025, 4)) }.to raise_error(Sequel::ConstraintViolation)
    end

    it "fails to create in the distant future" do
      expect { insert_row(Time.now + 60 * 60 * 24 * 365 * 10) }.to raise_error(Sequel::ConstraintViolation)
    end
  end
end
