# frozen_string_literal: true

module Authorization
  class Unauthorized < CloverError
    def initialize
      super(403, "Forbidden", "Sorry, you don't have permission to continue with this request.")
    end
  end

  def self.has_permission?(subject_id, actions, object_id)
    !matched_policies_dataset(subject_id, actions, object_id).empty?
  end

  def self.authorize(subject_id, actions, object_id)
    unless has_permission?(subject_id, actions, object_id)
      fail Unauthorized
    end
  end

  def self.all_permissions(subject_id, object_id)
    matched_policies_dataset(subject_id, nil, object_id).select_map(:actions).tap(&:flatten!)
  end

  def self.authorized_resources_dataset(subject_id, actions)
    matched_policies_dataset(subject_id, actions).select(Sequel[:applied_tag][:tagged_id])
  end

  def self.expand_actions(actions)
    extended_actions = Set["*"]
    Array(actions).each do |action|
      extended_actions << action
      parts = action.split(":")
      parts[0..-2].each_with_index.each { |_, i| extended_actions << "#{parts[0..i].join(":")}:*" }
    end
    extended_actions.to_a
  end

  def self.matched_policies_dataset(subject_id, actions = nil, object_id = nil)
    dataset = DB.from { access_policy.as(:acl) }
      .select(Sequel[:applied_tag][:tagged_id], Sequel[:applied_tag][:tagged_table], :subjects, :actions, :objects)
      .cross_join(Sequel.pg_jsonb_op(Sequel[:acl][:body])["acls"].to_recordset.as(:items, [:subjects, :actions, :objects].map { |c| Sequel.lit("#{c} JSONB") }))
      .join(:access_tag, project_id: Sequel[:acl][:project_id]) do
        Sequel.pg_jsonb_op(:objects).has_key?(Sequel[:access_tag][:name])
      end
      .join(:applied_tag, access_tag_id: :id)
      .join(:access_tag, {project_id: Sequel[:acl][:project_id]}, table_alias: :subject_access_tag) do
        Sequel.pg_jsonb_op(:subjects).has_key?(Sequel[:subject_access_tag][:name])
      end
      .join(:applied_tag, {access_tag_id: :id, tagged_id: subject_id}, table_alias: :subject_applied_tag)

    if object_id
      begin
        ubid = UBID.parse(object_id)
      rescue UBIDParseError
        # nothing
      else
        object_id = ubid.to_uuid
      end

      dataset = dataset.where(Sequel[:applied_tag][:tagged_id] => object_id)
    end

    if actions
      dataset = dataset.where(Sequel.pg_jsonb_op(:actions).contain_any(Sequel.pg_array(expand_actions(actions))))
    end

    dataset
  end

  def self.matched_policies(subject_id, actions = nil, object_id = nil)
    matched_policies_dataset(subject_id, actions, object_id).all
  end

  module ManagedPolicy
    ManagedPolicyClass = Struct.new(:name, :actions) do
      def acls(subjects, objects)
        {acls: [{subjects: Array(subjects), actions: actions, objects: Array(objects)}]}
      end

      def apply(project, accounts, append: false, remove_subjects: nil)
        subjects = accounts.map { _1&.hyper_tag(project) }.compact.map { _1.name }
        if append || remove_subjects
          if (existing_body = project.access_policies_dataset.where(name: name).select_map(:body).first)
            existing_subjects = existing_body["acls"].first["subjects"]

            case remove_subjects
            when Array
              existing_subjects = existing_subjects.reject { remove_subjects.include?(_1) }
            when String
              existing_subjects = existing_subjects.reject { _1.start_with?(remove_subjects) }
            end
            subjects = existing_subjects + subjects
            subjects.uniq!
          end
        end
        object = project.hyper_tag_name(project)
        acls = self.acls(subjects, object).to_json
        policy = AccessPolicy.new_with_id(project_id: project.id, name: name, managed: true, body: acls)
        policy.skip_auto_validations(:unique) do
          policy.insert_conflict(target: [:project_id, :name], update: {body: acls}).save_changes
        end
      end
    end

    Admin = ManagedPolicyClass.new("admin", ["*"])
    Member = ManagedPolicyClass.new("member", ["Vm:*", "PrivateSubnet:*", "Firewall:*", "Postgres:*", "Project:view", "Project:github"])

    def self.from_name(name)
      ManagedPolicy.const_get(name.to_s.capitalize)
    rescue NameError
      nil
    end
  end

  module Dataset
    def authorized(subject_id, actions)
      # We can't use "id" column directly, because it's ambiguous in big joined queries.
      # We need to determine table of id explicitly.
      # @opts is the hash of options for this dataset, and introduced at Sequel::Dataset.
      from = @opts[:from].first
      where { {Sequel[from][:id] => Authorization.authorized_resources_dataset(subject_id, actions)} }
    end
  end

  module HyperTagMethods
    def self.included(base)
      base.class_eval do
        many_to_many :projects, join_table: :access_tag, left_key: :hyper_tag_id, right_key: :project_id
      end
    end

    def hyper_tag_name(project = nil)
      raise NoMethodError
    end

    def hyper_tag(project)
      AccessTag.where(project_id: project.id, hyper_tag_id: id).first
    end

    def associate_with_project(project)
      return if project.nil?

      DB.transaction do
        self_tag = AccessTag.create_with_id(
          project_id: project.id,
          name: hyper_tag_name(project),
          hyper_tag_id: id,
          hyper_tag_table: self.class.table_name
        )
        project_tag = project.hyper_tag(project)
        tag(self_tag)
        tag(project_tag) if self_tag.id != project_tag.id
        self_tag
      end
    end

    def dissociate_with_project(project)
      return if project.nil?

      DB.transaction do
        project_tag = project.hyper_tag(project)
        untag(project_tag)
        hyper_tag(project).destroy
      end
    end
  end

  module TaggableMethods
    def self.included(base)
      base.class_eval do
        many_to_many :applied_access_tags, class: :AccessTag, join_table: :applied_tag, left_key: :tagged_id, right_key: :access_tag_id
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
