# frozen_string_literal: true

require_relative "../model"

class ResourceDiscount < Sequel::Model
  many_to_one :project, read_only: true

  plugin ResourceMethods

  def matches?(line_item)
    (resource_id.nil? || resource_id == line_item[:resource_id]) &&
      (resource_type.nil? || resource_type == line_item[:resource_type]) &&
      (resource_family.nil? || resource_family == line_item[:resource_family]) &&
      (location.nil? || location == line_item[:location]) &&
      (byoc.nil? || byoc == line_item[:byoc])
  end
end

# Table: resource_discount
# Columns:
#  id               | uuid                     | PRIMARY KEY
#  created_at       | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id       | uuid                     | NOT NULL
#  resource_id      | uuid                     |
#  resource_type    | text                     |
#  resource_family  | text                     |
#  location         | text                     |
#  byoc             | boolean                  |
#  discount_percent | numeric                  | NOT NULL
#  active_from      | timestamp with time zone | NOT NULL
#  active_to        | timestamp with time zone |
# Indexes:
#  resource_discount_pkey             | PRIMARY KEY btree (id)
#  resource_discount_project_id_index | btree (project_id)
# Check constraints:
#  resource_discount_active_range              | (active_to IS NULL OR active_from < active_to)
#  resource_discount_month_aligned             | (date_trunc('month'::text, active_from, 'UTC'::text) = active_from AND (active_to IS NULL OR date_trunc('month'::text, active_to, 'UTC'::text) = active_to))
#  resource_discount_percent_range             | (discount_percent >= 0::numeric AND discount_percent <= 100::numeric)
#  resource_discount_resource_id_requires_type | (resource_id IS NULL OR resource_type IS NOT NULL)
# Foreign key constraints:
#  resource_discount_project_id_fkey | (project_id) REFERENCES project(id)
# Triggers:
#  resource_discount_check_overlap | BEFORE INSERT OR UPDATE ON resource_discount FOR EACH ROW EXECUTE FUNCTION resource_discount_check_overlap()
