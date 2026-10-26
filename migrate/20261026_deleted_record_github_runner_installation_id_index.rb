# frozen_string_literal: true

Sequel.migration do
  up do
    columns = [Sequel.pg_jsonb_op(:model_values).get_text("installation_id"), :deleted_at]
    where = {model_name: "GithubRunner"}
    name = :deleted_record_github_runner_installation_id_index

    add_index(:deleted_record, columns, name:, where:, only: true) # rubocop:disable Sequel/ConcurrentIndex

    today = Time.now.utc.strftime("%Y_%m_%d")
    self[Sequel[:pg_inherits].as(:i)]
      .join(Sequel[:pg_class].as(:c), oid: Sequel[:i][:inhrelid])
      .where(Sequel[:i][:inhparent] => Sequel.cast("deleted_record", :regclass))
      .select_map(Sequel[:c][:relname])
      .select { it.match?(/\Adeleted_record_\d{4}_\d{2}_\d{2}\z/) && it.delete_prefix("deleted_record_") > today }
      .each do |partition|
        partition_index = :"#{partition}_github_runner_installation_id_index"
        add_index(partition.to_sym, columns, name: partition_index, where:) # rubocop:disable Sequel/ConcurrentIndex
        run "ALTER INDEX #{name} ATTACH PARTITION #{partition_index}"
      end
  end

  down do
    drop_index :deleted_record, nil, name: :deleted_record_github_runner_installation_id_index # rubocop:disable Sequel/ConcurrentIndex
  end
end
