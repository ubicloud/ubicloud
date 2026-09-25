# frozen_string_literal: true

require_relative "../model"

class DeletedRecord < Sequel::Model
  no_primary_key

  RETENTION_DAYS = 35   # How long to keep deleted_record partitions before dropping them

  plugin DailyPartitionMethods, partition_type: :timestamptz

  def self.find_by_id(id, model_name:, days: 5)
    DB[:deleted_record]
      .where(record_id: id, model_name:)
      .where { deleted_at > Sequel::CURRENT_TIMESTAMP - Sequel.cast("#{days} days", :interval) }
      .first
  end

  def self.vms_by_ips(ips, days: 5)
    ip_values = Sequel.pg_jsonb_op(Sequel[:ip][:model_values])
    vm_values = Sequel.pg_jsonb_op(Sequel[:vm][:model_values])
    last_n_days = Sequel::CURRENT_TIMESTAMP - Sequel.cast("#{days} days", :interval)
    DB.from(Sequel[:deleted_record].as(:ip))
      .join(Sequel[:deleted_record].as(:vm), Sequel.cast(ip_values.get_text("dst_vm_id"), :uuid) => Sequel[:vm][:record_id])
      .where(Sequel[:ip][:model_name] => "AssignedVmAddress")
      .where(Sequel[:vm][:model_name] => "Vm")
      .where(ip_values.get_text("ip") => ips)
      .where(Sequel[:ip][:deleted_at] > last_n_days)
      .where(Sequel[:vm][:deleted_at] > last_n_days)
      .select(
        ip_values.get_text("ip").as(:ip),
        Sequel[:ip][:deleted_at],
        Sequel.cast(vm_values.get_text("created_at"), :timestamptz).as(:created_at),
        ip_values.get_text("dst_vm_id").as(:vm_id),
        vm_values.get_text("name").as(:vm_name),
        vm_values.get_text("boot_image").as(:boot_image),
        vm_values.get_text("project_id").as(:project_id),
      )
      .reverse(Sequel[:ip][:deleted_at])
      .all
  end
end

# Table: deleted_record
# Columns:
#  deleted_at   | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  model_name   | text                     | NOT NULL
#  record_id    | uuid                     |
#  model_values | jsonb                    | NOT NULL
# Indexes:
#  deleted_record_deleted_at_index            | brin (deleted_at)
#  deleted_record_model_name_deleted_at_index | btree (model_name, deleted_at)
#  deleted_record_record_id_index             | btree (record_id) WHERE record_id IS NOT NULL
