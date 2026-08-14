# frozen_string_literal: true

require_relative "../model"

class PageSnooze < Sequel::Model
  dataset_module do
    where(:active, Sequel::CURRENT_TIMESTAMP < :snooze_until)
  end

  plugin ResourceMethods, etc_type: true
end

# Table: page_snooze
# Columns:
#  id           | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  page_id      | uuid                     | NOT NULL
#  created_at   | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  snooze_until | timestamp with time zone | NOT NULL
#  snoozed_by   | text                     | NOT NULL
#  note         | text                     | NOT NULL
# Indexes:
#  page_snooze_pkey          | PRIMARY KEY btree (id)
#  page_snooze_page_id_index | btree (page_id)
# Foreign key constraints:
#  page_snooze_page_id_fkey | (page_id) REFERENCES page(id) ON DELETE CASCADE
