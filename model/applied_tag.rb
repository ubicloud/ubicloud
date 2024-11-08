# frozen_string_literal: true

require_relative "../model"

class AppliedTag < Sequel::Model
  many_to_one :access_tag
end

AppliedTag.unrestrict_primary_key

# Table: applied_tag
# Primary Key: (access_tag_id, tagged_id)
# Columns:
#  access_tag_id | uuid |
#  tagged_id     | uuid |
#  tagged_table  | text | NOT NULL
# Indexes:
#  applied_tag_pkey            | PRIMARY KEY btree (access_tag_id, tagged_id)
#  applied_tag_tagged_id_index | btree (tagged_id)
# Foreign key constraints:
#  applied_tag_access_tag_id_fkey | (access_tag_id) REFERENCES access_tag(id)
