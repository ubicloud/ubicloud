# frozen_string_literal: true

require_relative "../model"

class AccessPolicy < Sequel::Model
  many_to_one :project

  include ResourceMethods

  def transform_to_names
    tag_to_name = project.accounts.map { [_1.hyper_tag_name, _1.policy_tag_name] }.to_h
    transform(tag_to_name)
    self
  end

  def transform_to_tags
    name_to_tag = project.accounts.map { [_1.policy_tag_name, _1.hyper_tag_name] }.to_h
    transform(name_to_tag)
    self
  end

  def transform(lookup)
    body["acls"] = body["acls"].map do
      _1.tap { |acl|
        acl["subjects"] = value_from_lookup(lookup, acl["subjects"])
        acl["objects"] = value_from_lookup(lookup, acl["objects"])
      }
    end
  end

  def value_from_lookup(lookup, key)
    return key.map { value_from_lookup(lookup, _1) } if key.is_a?(Array)
    if key.start_with?("user/")
      lookup.fetch(key) { fail Validation::ValidationFailed.new({body: "'#{key}' doesn't exists in your project."}) }
    else
      lookup[key] || key
    end
  end
end

# We need to unrestrict primary key so project.add_access_policy works
# in model/account.rb.
AccessPolicy.unrestrict_primary_key
