# frozen_string_literal: true

require_relative "../model"

class Firewall < Sequel::Model
  many_to_one :project
  one_to_many :firewall_rules, order: :cidr, remover: nil, clearer: nil
  many_to_many :private_subnets
  many_to_one :location
  plugin :association_dependencies, firewall_rules: :destroy

  plugin ResourceMethods
  include ObjectTag::Cleanup

  dataset_module Pagination

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/firewall/#{name}"
  end

  def remove_firewall_rule(firewall_rule)
    firewall_rules_dataset.where(id: firewall_rule.id).destroy
    update_private_subnet_firewall_rules
  end

  def insert_firewall_rule(cidr, port_range, description: nil)
    fwr = add_firewall_rule(cidr:, port_range:, description:)
    update_private_subnet_firewall_rules
    fwr
  end

  def replace_firewall_rules(new_firewall_rules)
    firewall_rules.each(&:destroy)
    DB.ignore_duplicate_queries do
      new_firewall_rules.each do
        add_firewall_rule(it)
      end
    end

    update_private_subnet_firewall_rules
  end

  def before_destroy
    update_private_subnet_firewall_rules
    remove_all_private_subnets
    super
  end

  # GCP NICs have a hard limit of 10 secure tag bindings (see
  # Prog::Vnet::Gcp::UpdateFirewallRules::GCP_MAX_TAGS_PER_NIC). One slot
  # is always consumed by the subnet "member" tag, which leaves 9 for
  # per-firewall tags.
  GCP_MAX_FIREWALLS_PER_VM = 9

  def self.validate_gcp_firewall_cap!(vm, additional_firewall_ids: [])
    return unless vm.location.gcp?
    firewall_ids = vm.firewalls.map(&:id).to_set
    additional_firewall_ids.each { firewall_ids << it }
    if firewall_ids.size > GCP_MAX_FIREWALLS_PER_VM
      fail Validation::ValidationFailed.new(firewall: "GCP VMs cannot be attached to more than #{GCP_MAX_FIREWALLS_PER_VM} firewalls")
    end
  end

  # Acquire a row-level lock on the private_subnet row that serializes all
  # cap-sensitive mutations on that subnet. Both the VM-joins-subnet path
  # (Prog::Vm::Nexus.assemble) and the firewall-joins-subnet path
  # (Firewall#associate_with_private_subnet) must call this inside a
  # transaction before reading firewall/vm counts, so the two paths can't
  # each pass a stale snapshot check and both commit over the 9-cap.
  def self.lock_subnet_for_gcp_cap!(private_subnet)
    PrivateSubnet.where(id: private_subnet.id).for_update.first!
  end

  def associate_with_private_subnet(private_subnet, apply_firewalls: true)
    DB.transaction do
      if private_subnet.location.gcp?
        Firewall.lock_subnet_for_gcp_cap!(private_subnet)
        DB.ignore_duplicate_queries do
          private_subnet.vms_dataset.all.each do |vm|
            Firewall.validate_gcp_firewall_cap!(vm, additional_firewall_ids: [id])
          end
        end
      end
      add_private_subnet(private_subnet)
    end
    private_subnet.incr_update_firewall_rules if apply_firewalls
  end

  def disassociate_from_private_subnet(private_subnet, apply_firewalls: true)
    remove_private_subnet(private_subnet)
    private_subnet.incr_update_firewall_rules if apply_firewalls
  end

  def update_private_subnet_firewall_rules
    private_subnets.each(&:incr_update_firewall_rules)
  end
end

# Table: firewall
# Columns:
#  id          | uuid                        | PRIMARY KEY
#  name        | text                        | NOT NULL DEFAULT 'Default'::text
#  description | text                        | NOT NULL DEFAULT 'Default firewall'::text
#  created_at  | timestamp without time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id  | uuid                        | NOT NULL
#  location_id | uuid                        | NOT NULL
# Indexes:
#  firewall_pkey                             | PRIMARY KEY btree (id)
#  firewall_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  firewall_location_id_fkey | (location_id) REFERENCES location(id)
#  firewall_project_id_fkey  | (project_id) REFERENCES project(id)
# Referenced By:
#  firewall_rule             | firewall_rule_firewall_id_fkey             | (firewall_id) REFERENCES firewall(id)
#  firewalls_private_subnets | firewalls_private_subnets_firewall_id_fkey | (firewall_id) REFERENCES firewall(id)
#  firewalls_vms             | firewalls_vms_firewall_id_fkey             | (firewall_id) REFERENCES firewall(id) ON DELETE CASCADE
