# frozen_string_literal: true

module ResourceMatchable
  module ClassMethods
    Sequel::Plugins.def_dataset_methods(self, [:for_project, :active_during])
  end

  module InstanceMethods
    def matches?(line_item)
      (resource_id.nil? || resource_id == line_item[:resource_id]) &&
        (resource_type.nil? || resource_type == line_item[:resource_type]) &&
        (resource_family.nil? || resource_family == line_item[:resource_family]) &&
        (location.nil? || location == line_item[:location]) &&
        (byoc.nil? || byoc == line_item[:byoc])
    end

    def wildcard?
      resource_id.nil? && resource_type.nil? && resource_family.nil? && location.nil? && byoc.nil?
    end
  end

  module DatasetMethods
    def for_project(project_id)
      where(project_id:)
    end

    def active_during(begin_time, end_time)
      where { active_from < end_time }
        .where { (active_to > begin_time) | {active_to: nil} }
    end
  end
end
