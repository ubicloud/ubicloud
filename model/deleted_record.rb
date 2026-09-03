# frozen_string_literal: true

require_relative "../model"

class DeletedRecord < Sequel::Model
  no_primary_key

  RETENTION_DAYS = 35   # How long to keep deleted_record partitions before dropping them
  RUNWAY_DAYS = 14      # Create partitions through this many days from today
  MIN_RUNWAY_DAYS = 7   # Runway at which to page

  PARTITION_NAME_REGEXP = /\Adeleted_record_(\d{4})_(\d{2})_(\d{2})\z/

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

  def self.partition_name(day)
    "deleted_record_#{day.strftime("%Y_%m_%d")}"
  end

  def self.partition_days
    DB[Sequel[:pg_inherits].as(:i)]
      .join(Sequel[:pg_class].as(:c), oid: Sequel[:i][:inhrelid])
      .where(Sequel[:i][:inhparent] => Sequel.cast("deleted_record", :regclass))
      .select_map(Sequel[:c][:relname])
      .filter_map { PARTITION_NAME_REGEXP.match(it) }
      .map! { Date.new(it[1].to_i, it[2].to_i, it[3].to_i) }
      .sort!
  end

  def self.partition_runway_days
    days = partition_days.to_set
    return if days.empty?

    (Time.now.utc.to_date..).take_while { days.include?(it) }.count - 1
  end

  def self.ensure_partitions(through:)
    existing = partition_days.to_set
    (Time.now.utc.to_date..through).reject { existing.include?(it) }.each { create_partition(it) }
  end

  def self.create_partition(day)
    name = partition_name(day).to_sym
    next_day = day + 1

    DB["CREATE TABLE ? (LIKE deleted_record INCLUDING ALL)", name].run

    DB[<<~SQL, name, Time.utc(day.year, day.month, day.day), Time.utc(next_day.year, next_day.month, next_day.day)].no_auto_parameterize.run
      ALTER TABLE deleted_record ATTACH PARTITION ?
        FOR VALUES FROM (?) TO (?)
    SQL
  end

  def self.drop_partition(day)
    DB.transaction do
      DB.run("SET LOCAL lock_timeout = '5s'")
      DB.drop_table(partition_name(day))
    end
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
