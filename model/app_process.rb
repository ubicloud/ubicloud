# frozen_string_literal: true

require_relative "../model"

class AppProcess < Sequel::Model
  many_to_one :project, read_only: true
  many_to_one :location, read_only: true
  many_to_one :private_subnet, read_only: true
  one_to_many :app_process_members, read_only: true
  one_to_many :app_release_snapshots, read_only: true
  one_to_many :app_process_inits, read_only: true

  plugin ResourceMethods
  include ObjectTag::Cleanup

  dataset_module Pagination

  def before_destroy
    app_process_inits_dataset.destroy
    app_process_members_dataset.destroy
    app_release_snapshots_dataset.destroy
    super
  end

  def display_location
    location.display_name
  end

  def flat_name
    "#{group_name}-#{name}"
  end

  def display_name
    "#{group_name}/#{name}"
  end

  def path
    "/location/#{display_location}/app/#{flat_name}"
  end

  def active_members
    app_process_members_dataset.where(state: "active")
  end

  def vm_count
    app_process_members_dataset.count
  end

  def deployment_managed?
    !umi_id.nil?
  end

  def next_ordinal
    (app_process_members_dataset.max(:ordinal) || -1) + 1
  end

  # Returns all processes in the same group at the same location
  def group_processes
    project.app_processes_dataset
      .where(group_name: group_name, location_id: location_id)
      .order(:name)
      .all
  end

  # Returns subnet IDs owned by the app group (for filtering → lines)
  def group_subnet_ids
    project.app_processes_dataset
      .where(group_name: group_name, location_id: location_id)
      .exclude(private_subnet_id: nil)
      .select_map(:private_subnet_id)
  end

  # Returns external connected subnet names (subnets outside the app group)
  def external_connected_subnet_names
    return [] unless private_subnet_id
    group_ids = group_subnet_ids
    private_subnet.connected_subnets
      .reject { group_ids.include?(it.id) }
      .map(&:name)
  end

  # Resolve LB for this process type via its subnet
  def load_balancer
    return nil unless private_subnet_id
    LoadBalancer.first(private_subnet_id: private_subnet_id)
  end

  def has_lb?
    !load_balancer.nil?
  end

  # Latest release number for this group
  def latest_release_number
    AppRelease.where(project_id: project_id, group_name: group_name)
      .max(:release_number)
  end
end

# Table: app_process
# Columns:
#  id                | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(342)
#  group_name        | text    | NOT NULL
#  name              | text    | NOT NULL
#  project_id        | uuid    | NOT NULL
#  location_id       | uuid    | NOT NULL
#  desired_count     | integer | NOT NULL DEFAULT 0
#  vm_size           | text    |
#  umi_id            | uuid    |
#  private_subnet_id | uuid    |
#  umi_ref           | text    |
# Indexes:
#  app_process_pkey                                       | PRIMARY KEY btree (id)
#  app_process_project_id_location_id_group_name_name_key | UNIQUE btree (project_id, location_id, group_name, name)
#  app_process_project_id_index                           | btree (project_id)
# Foreign key constraints:
#  app_process_location_id_fkey       | (location_id) REFERENCES location(id)
#  app_process_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  app_process_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  app_process_init     | app_process_init_app_process_id_fkey     | (app_process_id) REFERENCES app_process(id)
#  app_process_member   | app_process_member_app_process_id_fkey   | (app_process_id) REFERENCES app_process(id)
#  app_release_snapshot | app_release_snapshot_app_process_id_fkey | (app_process_id) REFERENCES app_process(id)
