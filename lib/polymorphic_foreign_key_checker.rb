# frozen_string_literal: true

module PolymorphicForeignKeyChecker
  DEFAULT_CHECKS = [
    [:access_control_entry, :subject_id, :action_id, :object_id],
    [:api_key, :owner_id],
    [:applied_action_tag, :action_id],
    [:applied_object_tag, :object_id],
    [:applied_subject_tag, :subject_id],
    [:github_runner, :vm_id],
    [:page_root_resource, :root_resource_id],
    [:postgres_resource, :project_id, :parent_id],
    [:postgres_server, :resource_id, :physical_slot_ready_id],
    [:postgres_timeline, :parent_id],
    [:project_quota, :quota_id],
    [:resource_discount, :resource_id],
  ].freeze.each(&:freeze)

  def self.check_all
    DEFAULT_CHECKS.flat_map { check(*it) }
  end

  def self.check(table, *columns)
    ds = DB[table].distinct.skip_locked
    columns.filter_map do |column|
      uuid_hash = ds.exclude(column => nil).select_hash(column, Sequel[nil].as(:v))
      UBID.resolve_map(uuid_hash)
      uuid_hash.delete_if { |_, v| v }
      unless uuid_hash.empty?
        [table, column, uuid_hash.keys.map { UBID.to_ubid(it) }]
      end
    end
  end
end
