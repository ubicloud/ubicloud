# frozen_string_literal: true

module Authorization
  class Unauthorized < CloverError
    def initialize
      super(403, "Forbidden", "Sorry, you don't have permission to continue with this request.")
    end
  end

  def self.has_permission?(subject_id, actions, object_id)
    !matched_policies(subject_id, actions, object_id).empty?
  end

  def self.authorize(subject_id, actions, object_id)
    unless has_permission?(subject_id, actions, object_id)
      fail Unauthorized
    end
  end

  def self.all_permissions(subject_id, object_id)
    matched_policies(subject_id, nil, object_id).flat_map { _1[:actions] }
  end

  def self.authorized_resources(subject_id, actions)
    matched_policies(subject_id, actions).map { _1[:tagged_id] }
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

  def self.matched_policies(subject_id, actions = nil, object_id = nil)
    object_filter = if object_id
      begin
        Sequel.lit("AND object_applied_tags.tagged_id = ?", UBID.parse(object_id).to_uuid)
      rescue UBIDParseError
        Sequel.lit("AND object_applied_tags.tagged_id = ?", object_id)
      end
    else
      Sequel.lit("")
    end

    actions_filter = if actions
      Sequel.lit("AND actions ?| array[:actions]", {actions: Sequel.pg_array(expand_actions(actions))})
    else
      Sequel.lit("")
    end

    DB[<<~SQL, {subject_id: subject_id, actions_filter: actions_filter, object_filter: object_filter}].all
      SELECT object_applied_tags.tagged_id, object_applied_tags.tagged_table, subjects, actions, objects
      FROM accounts AS subject
        JOIN applied_tag AS subject_applied_tags ON subject.id = subject_applied_tags.tagged_id
          JOIN access_tag AS subject_access_tags ON subject_applied_tags.access_tag_id = subject_access_tags.id
          JOIN access_policy AS acl ON subject_access_tags.project_id = acl.project_id
          JOIN jsonb_to_recordset(acl.body->'acls') as items(subjects JSONB, actions JSONB, objects JSONB) ON TRUE
          JOIN access_tag AS object_access_tags ON subject_access_tags.project_id = object_access_tags.project_id
          JOIN applied_tag AS object_applied_tags ON object_access_tags.id = object_applied_tags.access_tag_id AND objects ? object_access_tags."name"
      WHERE subject.id = :subject_id
        AND subjects ? subject_access_tags."name"
        :actions_filter
        :object_filter
    SQL
  end

  def self.generate_default_acls(subject, object)
    {
      acls: [
        {subjects: [subject], actions: ["*"], objects: [object]}
      ]
    }
  end

  module ManagedPolicy
    ManagedPolicyClass = Struct.new(:name, :actions) do
      def acls(subjects, objects)
        {acls: [{subjects: Array(subjects), actions: actions, objects: Array(objects)}]}
      end

      def apply(project, accounts, append: false)
        subjects = accounts.map { _1&.hyper_tag(project) }.compact.map { _1.name }
        if append && (existing_body = project.access_policies_dataset.where(name: name).select_map(:body).first)
          subjects = (subjects + existing_body["acls"].first["subjects"]).uniq
        end
        objects = project.hyper_tag_name(project)
        acls = self.acls(subjects, objects).to_json
        policy = AccessPolicy.new_with_id(project_id: project.id, name: name, managed: true, body: acls)
        policy.skip_auto_validations(:unique) do
          policy.insert_conflict(target: [:project_id, :name], update: {body: acls}).save_changes
        end
      end
    end

    ADMIN = ManagedPolicyClass.new("admin", ["*"])
    MEMBER = ManagedPolicyClass.new("member", ["Vm:*", "PrivateSubnet:*", "Firewall:*", "Postgres:*", "Project:view", "Project:github"])

    def self.from_name(name)
      ManagedPolicy.const_get(name.upcase)
    end
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
