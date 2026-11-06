# frozen_string_literal: true

require "json"
module TerraformHarness
  # Post-example cleanup for specs that commit for real. At suite start
  # it snapshots the pristine seed state (rows created by migrations);
  # after each example it deletes everything else.
  #
  # Deletion runs on its own superuser connection with
  # `session_replication_role = replica`, suspending FK enforcement so
  # no dependency ordering is needed (the sweep removes every non-seed
  # row, so no orphans can survive it). TRUNCATE ... CASCADE is not an
  # option: seed tables can reference swept ones (location.project_id),
  # and the cascade would eat them.
  module DatabaseJanitor
    # Tables whose migration-seeded rows must survive sweeps. All are
    # pure seed data except strand, which examples also add to; it is
    # swept by ID against the suite-start snapshot.
    class << self
      def snapshot!
        db_name = DB.opts[:database]
        # Sweeps delete indiscriminately; insist on a dedicated,
        # numbered test database index (e.g. clover_test9) so a stray
        # run can't hollow out the shared default DB.
        unless /test[1-9]\d*\z/.match?(db_name.to_s)
          raise "spec/terraform must run against a dedicated test database " \
                "index (TEST_ENV_NUMBER), not #{db_name.inspect}"
        end

        @admin = Sequel.postgres(**DB.opts, user: "postgres")

        # The snapshot trusts "has rows now" to mean "seeded by
        # migrations", which only holds on a clean database. Canary
        # tables that only examples populate must be empty; a crashed
        # earlier run leaves residue, and the fix is recreating the
        # index (dropdb + createdb + migrate), not guessing here.
        if (dirty = %i[accounts project firewall postgres_resource vm].select { DB[it].count.positive? }).any?
          # A killed run (SIGKILL skips hooks) leaves residue. If a
          # persisted seed snapshot from a clean boot matches this
          # schema, self-recover: load it, sweep, and proceed.
          persisted = load_persisted_snapshot
          unless persisted
            raise "test database #{db_name} has residue in #{dirty.join(", ")} " \
                  "and no matching persisted seed snapshot; recreate the index"
          end
          @seed_tables, @seed_strand_ids, @sweep_tables =
            persisted.values_at("seed_tables", "seed_strand_ids", "sweep_tables")
              .then { [_1.map(&:to_sym), _2, _3.map(&:to_sym)] }
          sweep!
        end

        # Migration bookkeeping is out of scope entirely; the password
        # variant isn't even readable by the app role.
        tables = DB.tables - [:schema_migrations, :schema_migrations_password]
        @seed_tables = tables.select { DB[it].count.positive? }
        @seed_strand_ids = DB[:strand].select_map(:id)
        @sweep_tables = tables - @seed_tables
        persist_snapshot!
      end

      def snapshot_path
        "/tmp/tf_janitor_#{DB.opts[:database]}.json"
      end

      def schema_fingerprint = DB[:schema_migrations].count

      def persist_snapshot!
        File.write(snapshot_path, JSON.generate(
          fingerprint: schema_fingerprint,
          seed_tables: @seed_tables, seed_strand_ids: @seed_strand_ids,
          sweep_tables: @sweep_tables,
        ))
      end

      def load_persisted_snapshot
        return unless File.exist?(snapshot_path)
        data = JSON.parse(File.read(snapshot_path))
        data if data["fingerprint"] == schema_fingerprint
      end

      def sweep!
        @admin.transaction do
          @admin.run "SET LOCAL session_replication_role = replica"
          @sweep_tables.each { @admin[it].delete }
          @admin[:strand].exclude(id: @seed_strand_ids).delete
        end
      end
    end
  end
end
