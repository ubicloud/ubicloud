# frozen_string_literal: true

require_relative "../model"

class Account < Sequel::Model(:accounts)
  one_to_many :usage_alerts, key: :user_id

  plugin :association_dependencies, usage_alerts: :destroy

  include ResourceMethods
  include Authorization::HyperTagMethods

  def hyper_tag_name(project = nil)
    "user/#{email}"
  end

  include Authorization::TaggableMethods

  def create_project_with_default_policy(name, default_policy: Authorization::ManagedPolicy::Admin)
    project = Project.create_with_id(name: name)
    project.associate_with_project(project)
    associate_with_project(project)
    default_policy&.apply(project, [self])
    project
  end

  def suspend
    update(suspended_at: Time.now)
    DB[:account_active_session_keys].where(account_id: id).delete(force: true)

    projects.each { _1.billing_info&.payment_methods_dataset&.update(fraud: true) }
  end
end
