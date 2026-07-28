# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    dupes = from(:postgres_server)
      .where(timeline_access: "push")
      .group_by(:timeline_id)
      .having { count.function.* >= 2 }
      .select_map(:timeline_id)
    unless dupes.empty?
      raise Sequel::Error, "Refusing to add unique push-per-timeline index; timelines with more than one push server: #{dupes.inspect}"
    end

    alter_table(:postgres_server) do
      add_index :timeline_id, unique: true, where: {timeline_access: "push"}, concurrently: true, name: "postgres_server_timeline_id_push_idx"
    end
  end

  down do
    alter_table(:postgres_server) do
      drop_index :timeline_id, name: "postgres_server_timeline_id_push_idx", concurrently: true
    end
  end
end
