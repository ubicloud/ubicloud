# frozen_string_literal: true

require "yaml"

Sequel.migration do
  up do
    # Flip the resource_tags default from [] to {} and migrate existing rows so
    # downstream code can treat the column as a plain object.
    alter_table(:billing_record) do
      set_column_default :resource_tags, "{}"
    end
    from(:billing_record).where(resource_tags: Sequel.pg_jsonb_wrap([])).update(resource_tags: Sequel.pg_jsonb_wrap({}))

    rates = YAML.load_file("config/billing_rates.yml", permitted_classes: [Time])

    primary_slot = {"PostgresVCpu" => "primary-vcpu", "PostgresCores" => "primary-vcpu", "PostgresStorage" => "primary-storage"}
    standby_type = {"PostgresStandbyVCpu" => "standby-vcpu", "PostgresStandbyCores" => "standby-vcpu", "PostgresStandbyStorage" => "standby-storage"}

    rate_to_slot = {}
    rates.each do |r|
      rate_to_slot[r["id"]] = primary_slot[r["resource_type"]] if primary_slot.key?(r["resource_type"])
      rate_to_slot[r["id"]] = standby_type[r["resource_type"]] if standby_type.key?(r["resource_type"])
    end

    # Update primary records — each resource has exactly one active record per primary type
    rates.select { primary_slot.key?(it["resource_type"]) }.each do |r|
      from(:billing_record)
        .where(billing_rate_id: r["id"])
        .where(Sequel.function(:upper, :span) => nil)
        .update(resource_tags: Sequel.pg_jsonb_op(:resource_tags).concat({"slot" => rate_to_slot[r["id"]]}))
    end

    # Update standby records — a resource may have multiple active standby records
    # of the same type, so we assign standby-vcpu-0, standby-vcpu-1, etc. ordered by id.
    rates.select { standby_type.key?(it["resource_type"]) }.each do |r|
      suffix = rate_to_slot[r["id"]]
      run <<~SQL
        UPDATE billing_record
        SET resource_tags = billing_record.resource_tags || jsonb_build_object('slot', '#{suffix}-' || (rn - 1))
        FROM (
          SELECT id, ROW_NUMBER() OVER (PARTITION BY resource_id ORDER BY id) AS rn
          FROM billing_record
          WHERE billing_rate_id = '#{r["id"]}' AND upper(span) IS NULL
        ) sub
        WHERE billing_record.id = sub.id
      SQL
    end
  end

  down do
    nil
  end
end
