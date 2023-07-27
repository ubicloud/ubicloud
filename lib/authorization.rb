# frozen_string_literal: true

module Authorization
  class Unauthorized < StandardError; end

  def self.has_permission?(subject_id, actions, object_id)
    !matched_policies(subject_id, actions, object_id).empty?
  end

  def self.authorize(subject_id, actions, object_id)
    unless has_permission?(subject_id, actions, object_id)
      fail Unauthorized
    end
  end

  def self.authorized_resources(subject_id, actions)
    matched_policies(subject_id, actions).map { _1[:tagged_id] }
  end

  def self.matched_policies(subject_id, actions, object_id = nil)
    object_filter = if object_id
      Sequel.lit("AND object_applied_tags.tagged_id = ?", object_id)
    else
      Sequel.lit("")
    end

    DB[<<~SQL, {subject_id: subject_id, actions: Sequel.pg_array(Array(actions)), object_filter: object_filter}].all
      SELECT object_applied_tags.tagged_id, object_applied_tags.tagged_table, subjects, actions, objects
      FROM accounts AS subject
        JOIN applied_tag AS subject_applied_tags ON subject.id = subject_applied_tags.tagged_id
          JOIN access_tag AS subject_access_tags ON subject_applied_tags.access_tag_id = subject_access_tags.id
          JOIN access_policy AS acl ON subject_access_tags.project_id = acl.project_id
          JOIN jsonb_to_recordset(acl.body->'acls') as items(subjects JSONB, actions JSONB, objects JSONB) ON TRUE
          JOIN access_tag AS object_access_tags ON subject_access_tags.project_id = object_access_tags.project_id
          JOIN applied_tag AS object_applied_tags ON object_access_tags.id = object_applied_tags.access_tag_id AND objects ? object_access_tags."name"
      WHERE subject.id = :subject_id
        AND actions ?| array[:actions]
        AND subjects ? subject_access_tags."name"
        :object_filter
    SQL
  end

  def self.generate_default_acls(subject, object)
    {
      acls: [
        {subjects: [subject], actions: ["Project:view", "Project:delete", "Project:user", "Project:policy"], objects: [object]},
        {subjects: [subject], actions: ["Vm:view", "Vm:create", "Vm:delete"], objects: [object]},
        {subjects: [subject], actions: ["PrivateSubnet:view", "PrivateSubnet:create", "PrivateSubnet:delete", "PrivateSubnet:nic"], objects: [object]}
      ]
    }
  end

  module Dataset
    def authorized(subject_id, actions)
      # We can't use "id" column directly, because it's ambiguous in big joined queries.
      # We need to determine table of id explicitly.
      # @opts is the hash of options for this dataset, and introduced at Sequel::Dataset.
      from = @opts[:from].first
      where { {Sequel[from][:id] => Authorization.authorized_resources(subject_id, actions)} }
    end
  end

  module HyperTagMethods
    def self.included(base)
      base.class_eval do
        many_to_many :projects, join_table: AccessTag.table_name, left_key: :hyper_tag_id, right_key: :project_id
      end
    end

    def hyper_tag_name(project = nil)
      raise NoMethodError
    end

    def hyper_tag(project)
      AccessTag.where(project_id: project.id, hyper_tag_id: id).first
    end

    def create_hyper_tag(project)
      AccessTag.create_with_id(
        project_id: project.id,
        name: hyper_tag_name(project),
        hyper_tag_id: id,
        hyper_tag_table: self.class.table_name
      )
    end

    def delete_hyper_tag(project)
      DB.transaction do
        tag = hyper_tag(project)
        AppliedTag.where(access_tag_id: tag.id).destroy
        tag.destroy
      end
    end

    def associate_with_project(project)
      return if project.nil?

      DB.transaction do
        self_tag = create_hyper_tag(project)
        project_tag = project.hyper_tag(project)
        tag(self_tag)
        tag(project_tag) if self_tag.id != project_tag.id
      end
    end

    def dissociate_with_project(project)
      return if project.nil?

      DB.transaction do
        project_tag = project.hyper_tag(project)
        untag(project_tag)
        delete_hyper_tag(project)
      end
    end
  end

  module TaggableMethods
    def self.included(base)
      base.class_eval do
        many_to_many :applied_access_tags, class: AccessTag, join_table: AppliedTag.table_name, left_key: :tagged_id, right_key: :access_tag_id
      end
    end

    def tag(access_tag)
      AppliedTag.create(access_tag_id: access_tag.id, tagged_id: id, tagged_table: self.class.table_name)
    end

    def untag(access_tag)
      AppliedTag.where(access_tag_id: access_tag.id, tagged_id: id).destroy
    end
  end
end
