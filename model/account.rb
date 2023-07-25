# frozen_string_literal: true

require_relative "../model"

class Account < Sequel::Model(:accounts)
  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "user/#{email}"
  end

  include Authorization::TaggableMethods

  def create_project_with_default_policy(name, policy_body = nil)
    project = Project.create(name: name) { _1.id = UBID.generate(UBID::TYPE_PROJECT).to_uuid }
    project.associate_with_project(project)
    associate_with_project(project)
    project.add_access_policy(
      name: "default",
      body: policy_body || Authorization.generate_default_acls(hyper_tag_name, project.hyper_tag_name),
      id: UBID.generate(UBID::TYPE_ACCESS_POLICY).to_uuid
    )
    project
  end
end
