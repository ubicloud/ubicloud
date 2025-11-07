# frozen_string_literal: true

require_relative "../model"

class Annotation < Sequel::Model
  plugin ResourceMethods
end

# Table: annotation
# Columns:
#  id                | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(341)
#  description       | text                     |
#  related_resources | uuid[]                   |
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  annotation_pkey | PRIMARY KEY btree (id)
