# frozen_string_literal: true

Sequel.extension :pg_array_ops

module AccessTagToProjectIdConverter
  # :nocov:
  def self.call
    failures = {}
    conversions = {}

    [:api_key, :firewall, :load_balancer, :minio_cluster, :private_subnet, :vm].each do |table|
      access_tag_ds = DB[:access_tag]
        .where(hyper_tag_id: Sequel[table][:id])
        .select(:hyper_tag_id, :project_id)
        .distinct
        .from_self
        .select_group(:hyper_tag_id)
        .select_append { array_agg(:project_id).as(:project_ids) }
        .from_self
        .where { {array_length(:project_ids, 1) => 1} }
        .select(Sequel.pg_array_op(:project_ids)[1])

      conversions[table] = DB[table].where(project_id: nil).update(project_id: access_tag_ds)
      missed = DB[table].where(project_id: nil).select_map(:id)
      failures[table] = missed unless missed.empty?
    end

    {conversions:, failures:}
  end
  # :nocov:
end
