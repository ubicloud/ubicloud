# frozen_string_literal: true

require_relative "../model"

class SshKeyRotator < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :sshable

  plugin ResourceMethods
  plugin SemaphoreMethods, :rotate_now
end

# Table: ssh_key_rotator
# Columns:
#  id               | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(824)
#  sshable_id       | uuid                     | NOT NULL
#  next_rotation_at | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  ssh_key_rotator_pkey           | PRIMARY KEY btree (id)
#  ssh_key_rotator_sshable_id_key | UNIQUE btree (sshable_id)
# Foreign key constraints:
#  ssh_key_rotator_sshable_id_fkey | (sshable_id) REFERENCES sshable(id) ON DELETE CASCADE
