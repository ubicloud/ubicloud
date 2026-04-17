# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:resource_discount) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :project_id, :project, type: :uuid, null: false
      column :resource_id, :uuid, null: true
      column :resource_type, :text, null: true
      column :resource_family, :text, null: true
      column :location, :text, null: true
      column :byoc, :bool, null: true
      column :discount_percent, :numeric, null: false
      column :active_from, :timestamptz, null: false
      column :active_to, :timestamptz, null: true

      constraint(:resource_discount_percent_range, "discount_percent >= 0 AND discount_percent <= 100")
      constraint(:resource_discount_resource_id_requires_type, "resource_id IS NULL OR resource_type IS NOT NULL")
      constraint(:resource_discount_active_range, "active_to IS NULL OR active_from < active_to")
      constraint(:resource_discount_month_aligned, "date_trunc('month', active_from, 'UTC') = active_from AND (active_to IS NULL OR date_trunc('month', active_to, 'UTC') = active_to)")

      index :project_id
    end

    run <<~SQL
      CREATE FUNCTION resource_discount_check_overlap() RETURNS TRIGGER LANGUAGE plpgsql AS $$
        BEGIN
          -- Skip the overlap check when active_to <= active_from. Building
          -- tstzrange(NEW.active_from, NEW.active_to, '[)') below would otherwise
          -- raise PG::DataException, masking the resource_discount_active_range
          -- check constraint that fires after this trigger and is the canonical
          -- rejection path for that case.
          IF NEW.active_to IS NOT NULL AND NEW.active_to <= NEW.active_from THEN
            RETURN NEW;
          END IF;
          IF EXISTS (
            SELECT 1 FROM resource_discount d
            WHERE d.id <> NEW.id
              AND d.project_id = NEW.project_id
              AND (d.resource_id     IS NULL OR NEW.resource_id     IS NULL OR d.resource_id     = NEW.resource_id)
              AND (d.resource_type   IS NULL OR NEW.resource_type   IS NULL OR d.resource_type   = NEW.resource_type)
              AND (d.resource_family IS NULL OR NEW.resource_family IS NULL OR d.resource_family = NEW.resource_family)
              AND (d.location        IS NULL OR NEW.location        IS NULL OR d.location        = NEW.location)
              AND (d.byoc            IS NULL OR NEW.byoc            IS NULL OR d.byoc            = NEW.byoc)
              AND tstzrange(d.active_from, d.active_to, '[)') && tstzrange(NEW.active_from, NEW.active_to, '[)')
          ) THEN
            RAISE EXCEPTION 'resource_discount overlaps with an existing discount for project %', NEW.project_id;
          END IF;
          RETURN NEW;
        END;
      $$
    SQL

    run <<~SQL
      CREATE TRIGGER resource_discount_check_overlap
      BEFORE INSERT OR UPDATE ON resource_discount
      FOR EACH ROW EXECUTE FUNCTION resource_discount_check_overlap()
    SQL
  end

  down do
    run "DROP TRIGGER resource_discount_check_overlap ON resource_discount"
    run "DROP FUNCTION resource_discount_check_overlap()"
    drop_table(:resource_discount)
  end
end
