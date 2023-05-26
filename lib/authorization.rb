# frozen_string_literal: true

module Authorization
  class Unauthorized < StandardError; end

  def self.has_power?(subject_id, powers, object_id)
    !matched_policies(subject_id, powers, object_id).empty?
  end

  def self.authorize(subject_id, powers, object_id)
    unless has_power?(subject_id, powers, object_id)
      fail Unauthorized
    end
  end

  def self.authorized_resources(subject_id, powers)
    matched_policies(subject_id, powers).map { _1[:tagged_id] }
  end

  def self.matched_policies(subject_id, powers, object_id = nil)
    object_filter = if object_id
      Sequel.lit("AND object_applied_tags.tagged_id = ?", object_id)
    else
      Sequel.lit("")
    end

    DB[<<~SQL, {subject_id: subject_id, powers: Sequel.pg_array(Array(powers)), object_filter: object_filter}].all
      SELECT object_applied_tags.tagged_id, object_applied_tags.tagged_table, subjects, powers, objects
      FROM accounts AS subject
        JOIN applied_tag AS subject_applied_tags ON subject.id = subject_applied_tags.tagged_id
          JOIN access_tag AS subject_access_tags ON subject_applied_tags.access_tag_id = subject_access_tags.id
          JOIN access_policy AS acl ON subject_access_tags.tag_space_id = acl.tag_space_id
          JOIN jsonb_to_recordset(acl.body->'acls') as items(subjects JSONB, powers JSONB, objects JSONB) ON TRUE
          JOIN access_tag AS object_access_tags ON subject_access_tags.tag_space_id = object_access_tags.tag_space_id
          JOIN applied_tag AS object_applied_tags ON object_access_tags.id = object_applied_tags.access_tag_id AND objects ? object_access_tags."name"
      WHERE subject.id = :subject_id
        AND powers ?| array[:powers]
        AND subjects ? subject_access_tags."name"
        :object_filter
    SQL
  end

  def self.generate_default_acls(subject, object)
    {
      acls: [
        {subjects: [subject], powers: ["TagSpace:view", "TagSpace:delete", "TagSpace:user", "TagSpace:policy"], objects: [object]},
        {subjects: [subject], powers: ["Vm:view", "Vm:create", "Vm:delete"], objects: [object]}
      ]
    }
  end

  module Dataset
    def authorized(subject_id, powers)
      where(id: Authorization.authorized_resources(subject_id, powers))
    end
  end

  module HyperTagMethods
    def self.included(base)
      base.class_eval do
        many_to_many :tag_spaces, join_table: AccessTag.table_name, left_key: :hyper_tag_id, right_key: :tag_space_id
      end
    end

    def hyper_tag_identifier
      :name
    end

    def hyper_tag_prefix
      self.class.name
    end

    def hyper_tag_name
      "#{hyper_tag_prefix}/#{send(hyper_tag_identifier)}"
    end

    def hyper_tag(tag_space)
      AccessTag.where(tag_space_id: tag_space.id, hyper_tag_id: id).first
    end

    def create_hyper_tag(tag_space)
      AccessTag.create(tag_space_id: tag_space.id, name: hyper_tag_name, hyper_tag_id: id, hyper_tag_table: self.class.table_name)
    end

    def delete_hyper_tag(tag_space)
      DB.transaction do
        tag = hyper_tag(tag_space)
        AppliedTag.where(access_tag_id: tag.id).delete
        tag.delete
      end
    end

    def associate_with_tag_space(tag_space)
      return if tag_space.nil?

      DB.transaction do
        self_tag = create_hyper_tag(tag_space)
        tag_space_tag = tag_space.hyper_tag(tag_space)
        tag(self_tag)
        tag(tag_space_tag) if self_tag.id != tag_space_tag.id
      end
    end

    def dissociate_with_tag_space(tag_space)
      return if tag_space.nil?

      DB.transaction do
        tag_space_tag = tag_space.hyper_tag(tag_space)
        untag(tag_space_tag)
        delete_hyper_tag(tag_space)
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
      AppliedTag.where(access_tag_id: access_tag.id, tagged_id: id).delete
    end
  end
end
