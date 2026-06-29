# frozen_string_literal: true

require_relative "../../model"

class GithubInstallationSpillOption < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_GITHUB_INSTALLATION
  many_to_one :installation, class: :GithubInstallation, key: :id
end

# Table: github_installation_spill_option
# Columns:
#  id              | uuid    | PRIMARY KEY
#  spill_ratio     | numeric | NOT NULL DEFAULT 0
#  vcpus_limit     | integer | NOT NULL
#  allocated_vcpus | integer | NOT NULL DEFAULT 0
# Indexes:
#  github_installation_spill_option_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  allocated_vcpus_non_negative | (allocated_vcpus >= 0)
#  allocated_vcpus_within_limit | (allocated_vcpus <= vcpus_limit)
#  spill_ratio_range            | (spill_ratio >= 0::numeric AND spill_ratio <= 1::numeric)
#  vcpus_limit_non_negative     | (vcpus_limit >= 0)
# Foreign key constraints:
#  github_installation_spill_option_id_fkey | (id) REFERENCES github_installation(id)
