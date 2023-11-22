# frozen_string_literal: true

require_relative "../model"

class Account < Sequel::Model(:accounts)
  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "user/#{email}"
  end

  include Authorization::TaggableMethods

  def create_project_with_default_policy(name, provider: Option::Provider::HETZNER, policy_body: nil)
    Validation.validate_provider(provider)
    project = Project.create_with_id(name: name, provider: provider)
    project.associate_with_project(project)
    associate_with_project(project)
    project.add_access_policy(
      id: AccessPolicy.generate_uuid,
      name: "default",
      body: policy_body || Authorization.generate_default_acls(hyper_tag_name, project.hyper_tag_name)
    )
    project
  end

  def suspend
    update(suspended_at: Time.now)
    DB[:account_active_session_keys].where(account_id: id).delete(force: true)
  end
end
