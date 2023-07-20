# frozen_string_literal: true

require_relative "../model"

class AccessPolicy < Sequel::Model
  many_to_one :project

  include ResourceMethods
end

# We need to unrestrict primary key so project.add_access_policy works
# in model/account.rb.
AccessPolicy.unrestrict_primary_key
