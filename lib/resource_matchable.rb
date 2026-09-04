# frozen_string_literal: true

module ResourceMatchable
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
end
