# frozen_string_literal: true

module Authorization
  class Unauthorized < CloverError
    def initialize
      super(403, "Forbidden", "Sorry, you don't have permission to continue with this request.")
    end
  end

  def self.has_permission?(project_id, subject_id, actions, object_id)
    !matched_policies_dataset(project_id, subject_id, actions, object_id).empty?
  end

  def self.authorize(project_id, subject_id, actions, object_id)
    unless has_permission?(project_id, subject_id, actions, object_id)
      fail Unauthorized
    end
  end

  def self.all_permissions(project_id, subject_id, object_id)
    # XXX: Need to use recursive CTEs for nested tag inclusion
    DB[:action_type]
      .with(:action_ids, matched_policies_dataset(project_id, subject_id, nil, object_id).select(:action_id))
      .where(Sequel.or([DB[:action_ids], DB[:applied_action_tag].select(:action_id).where(tag_id: DB[:action_ids])].map { [:id, _1] }) | DB[:action_ids].where(action_id: nil).exists)
      .select_order_map(:name)
  end

  def self.matched_policies_dataset(project_id, subject_id, actions = nil, object_id = nil)
    # XXX: Need to use recursive CTEs for nested tag inclusion
    dataset = DB[:access_control_entry]
      .where(project_id:)
      .where(Sequel.or([subject_id, DB[:applied_subject_tag].select(:tag_id).where(subject_id:)].map { [:subject_id, _1] }))

    if actions
      cond = Sequel.expr(action_id: nil)
      Array(actions).each do |action|
        action_id = ActionType::NAME_MAP.fetch(action)
        cond |= Sequel.or([action_id, DB[:applied_action_tag].select(:tag_id).where(action_id:)].map { [:action_id, _1] })
      end
      dataset = dataset.where(cond)
    end

    if object_id
      begin
        ubid = UBID.parse(object_id)
      rescue UBIDParseError
        # nothing
      else
        object_id = ubid.to_uuid
      end

      dataset = dataset.where(Sequel.or([nil, object_id, DB[:applied_object_tag].select(:tag_id).where(object_id:)].map { [:object_id, _1] }))
    end

    dataset
  end

  def self.matched_policies(project_id, subject_id, actions = nil, object_id = nil)
    matched_policies_dataset(project_id, subject_id, actions, object_id).all
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
    Member = ManagedPolicyClass.new("member", ["Vm:*", "PrivateSubnet:*", "Firewall:*", "Postgres:*", "Project:view", "Project:github", "InferenceEndpoint:view"])

    def self.from_name(name)
      ManagedPolicy.const_get(name.to_s.capitalize)
    rescue NameError
      nil
    end
  end

  module Dataset
    def authorized(project_id, subject_id, actions)
      # We can't use "id" column directly, because it's ambiguous in big joined queries.
      # We need to determine table of id explicitly.
      # @opts is the hash of options for this dataset, and introduced at Sequel::Dataset.
      from = @opts[:from].first

      # XXX: Need to use recursive CTEs for nested tag inclusion
      ds = DB[:object_ids]
        .union(DB[:applied_object_tag].select(:object_id).where(tag_id: DB[:object_ids]))
        .with(:object_ids, Authorization.matched_policies_dataset(project_id, subject_id, actions).select(:object_id))

      where(Sequel.|(
        # Allow where there is a specific entry for the object,
        {Sequel[from][:id] => ds},
        # or where the action is allowed for all objects in the project,
        (ds.where(object_id: nil).exists &
          # and the object is in the project via a hypertag.
          {project_id => DB[:access_tag].select(:project_id).where(hyper_tag_id: Sequel[from][:id])})
      ))
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
