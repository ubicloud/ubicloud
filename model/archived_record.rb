# frozen_string_literal: true

require_relative "../model"

class ArchivedRecord < Sequel::Model
  no_primary_key

  def self.find_by_id(id, model_name:, days: 15)
    DB[:archived_record]
      .where(model_name:)
      .where(Sequel[:archived_at] > Sequel::CURRENT_TIMESTAMP - Sequel.cast("#{days} days", :interval))
      .where(Sequel.pg_jsonb_op(:model_values).get_text("id") => id)
      .first
  end

  def self.vms_by_ips(ips)
    ip_values = Sequel.pg_jsonb_op(Sequel[:ip][:model_values])
    vm_values = Sequel.pg_jsonb_op(Sequel[:vm][:model_values])
    last_15_days = Sequel::CURRENT_TIMESTAMP - Sequel.cast("15 days", :interval)
    DB.from(Sequel[:archived_record].as(:ip))
      .join(Sequel[:archived_record].as(:vm), ip_values.get_text("dst_vm_id") => vm_values.get_text("id"))
      .where(Sequel[:ip][:model_name] => "AssignedVmAddress")
      .where(Sequel[:vm][:model_name] => "Vm")
      .where(ip_values.get_text("ip") => ips)
      .where(Sequel[:ip][:archived_at] > last_15_days)
      .where(Sequel[:vm][:archived_at] > last_15_days)
      .select(
        ip_values.get_text("ip").as(:ip),
        Sequel[:ip][:archived_at],
        Sequel.cast(vm_values.get_text("created_at"), :timestamptz).as(:created_at),
        ip_values.get_text("dst_vm_id").as(:vm_id),
        vm_values.get_text("name").as(:vm_name),
        vm_values.get_text("boot_image").as(:boot_image),
        vm_values.get_text("project_id").as(:project_id)
      )
      .reverse(Sequel[:ip][:archived_at])
      .all
  end
end

# Table: archived_record
# Columns:
#  archived_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  model_name   | text                     | NOT NULL
#  model_values | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
# Indexes:
#  archived_record_model_name_archived_at_index | btree (model_name, archived_at)
