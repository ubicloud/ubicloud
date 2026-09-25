# frozen_string_literal: true

# Manages daily range partitions for a model's table. Partitions are
# named "#{table_name}_YYYY_MM_DD" and each holds a single UTC day.
module DailyPartitionMethods
  # partition_type should be the type of the column the table is
  # partitioned by, either :date or :timestamptz.
  def self.configure(model, partition_type:)
    model.instance_exec do
      @partition_name_regexp = /\A#{table_name}_(\d{4})_(\d{2})_(\d{2})\z/
      @partition_type = partition_type
    end
  end

  module ClassMethods
    attr_reader :partition_name_regexp, :partition_type

    def partition_name(day)
      "#{table_name}_#{day.strftime("%Y_%m_%d")}"
    end

    def partition_days
      DB[Sequel[:pg_inherits].as(:i)]
        .join(Sequel[:pg_class].as(:c), oid: Sequel[:i][:inhrelid])
        .where(Sequel[:i][:inhparent] => Sequel.cast(table_name.to_s, :regclass))
        .select_map(Sequel[:c][:relname])
        .filter_map { partition_name_regexp.match(it) }
        .map! { Date.new(it[1].to_i, it[2].to_i, it[3].to_i) }
        .sort!
    end

    def partition_runway_days
      days = partition_days.to_set
      return if days.empty?

      (Time.now.utc.to_date..).take_while { days.include?(it) }.count - 1
    end

    def ensure_partitions(through:)
      existing = partition_days.to_set
      (Time.now.utc.to_date..through).reject { existing.include?(it) }.each { create_partition(it) }
    end

    def create_partition(day)
      name = partition_name(day).to_sym
      next_day = day + 1
      from, to = if partition_type == :timestamptz
        [Time.utc(day.year, day.month, day.day), Time.utc(next_day.year, next_day.month, next_day.day)]
      else
        [day, next_day]
      end

      table_name = self.table_name
      DB.create_table(name) do
        like table_name, including: :all
      end

      DB.alter_table(table_name) do
        attach_partition name do
          from from
          to to
        end
      end
    end

    def drop_partition(day)
      DB.transaction do
        DB.run("SET LOCAL lock_timeout = '5s'")
        DB.drop_table(partition_name(day))
      end
    end
  end
end
