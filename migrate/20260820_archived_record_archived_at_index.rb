# frozen_string_literal: true

Sequel.migration do
  # CREATE INDEX CONCURRENTLY is not supported inside transactions
  no_transaction

  up do
    run "CREATE INDEX IF NOT EXISTS archived_record_archived_at_index ON ONLY archived_record (archived_at)"

    attached = from(:pg_inherits)
      .join(:pg_class, oid: :inhrelid)
      .where(inhparent: Sequel.cast("archived_record_archived_at_index", :regclass))
      .select_map(:relname)

    from(:pg_inherits)
      .join(:pg_class, oid: :inhrelid)
      .where(inhparent: Sequel.cast("archived_record", :regclass))
      .order(:relname)
      .select_map(:relname)
      .each do |name|
        run "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name}_archived_at_index ON #{name} (archived_at)"
        unless attached.include?("#{name}_archived_at_index")
          run "ALTER INDEX archived_record_archived_at_index ATTACH PARTITION #{name}_archived_at_index"
        end
      end
  end

  down do
    run "DROP INDEX archived_record_archived_at_index"
  end
end
