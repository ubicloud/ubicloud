# frozen_string_literal: true

require "ulid"
require "mail"
require_relative "../model"

class Account < Sequel::Model(:accounts)
  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_identifier
    :email
  end

  def hyper_tag_prefix
    "User"
  end

  include Authorization::TaggableMethods

  def create_tag_space_with_default_policy(name, policy_body = nil)
    tag_space = TagSpace.create(name: name)
    tag_space.associate_with_tag_space(tag_space)
    associate_with_tag_space(tag_space)
    tag_space.add_access_policy(name: "default", body: policy_body || Authorization.generate_default_acls(hyper_tag_name, tag_space.hyper_tag_name))
    tag_space
  end

  # TODO: probably we need to get name from users
  def username
    "#{Mail::Address.new(email).local}_#{ULID.from_uuidish(id).to_s[0..5].downcase}"
  end
end
