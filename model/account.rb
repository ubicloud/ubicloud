# frozen_string_literal: true

require "mail"
require_relative "../model"

class Account < Sequel::Model(:accounts)
  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "user/#{email}"
  end

  include Authorization::TaggableMethods

  def create_project_with_default_policy(name, policy_body = nil)
    project = Project.create(name: name)
    project.associate_with_project(project)
    associate_with_project(project)
    project.add_access_policy(name: "default", body: policy_body || Authorization.generate_default_acls(hyper_tag_name, project.hyper_tag_name))
    project
  end

  # TODO: probably we need to get name from users
  def username
    "#{Mail::Address.new(email).local}-#{ulid.to_s[0..5].downcase}"
  end
end
