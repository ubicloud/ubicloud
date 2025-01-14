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
    DB[:action_type]
      .with(:action_ids, matched_policies_dataset(project_id, subject_id, nil, object_id).select(:action_id))
      .with_recursive(:rec_action_ids,
        DB[:applied_action_tag].select(:action_id, 0).where(tag_id: DB[:action_ids]),
        DB[:applied_action_tag].join(:rec_action_ids, action_id: :tag_id)
          .select(Sequel[:applied_action_tag][:action_id], Sequel[:level] + 1)
          .where { level < Config.recursive_tag_limit },
        args: [:action_id, :level])
      .where(Sequel.or([DB[:action_ids], DB[:rec_action_ids].select(:action_id)].map { [:id, _1] }) | DB[:action_ids].where(action_id: nil).exists)
      .select_order_map(:name)
  end

  # Used to avoid dynamic symbol creation at runtime
  RECURSIVE_TAG_QUERY_MAP = {
    subject: [:applied_subject_tag, :subject_id],
    action: [:applied_action_tag, :action_id],
    object: [:applied_object_tag, :object_id]
  }.freeze
  private_class_method def self.recursive_tag_query(type, values, project_id: nil)
    table, column = RECURSIVE_TAG_QUERY_MAP.fetch(type, values)

    base_ds = DB[table]
      .select(:tag_id, 0)
      .where(column => values)

    if project_id
      # We only look for applied_action_tag entries with an action_tag for the project or global action_tags.
      # This is done for actions and not subjects and objects because actions are shared
      # across projects, unlike subjects and objects.
      base_ds = base_ds.where(tag_id: DB[:action_tag].where(project_id:).or(project_id: nil).select(:id))
    end

    DB[:tag]
      .with_recursive(:tag,
        base_ds,
        DB[table].join(:tag, tag_id: column)
          .select(Sequel[table][:tag_id], Sequel[:level] + 1)
          .where { level < Config.recursive_tag_limit },
        args: [:tag_id, :level]).select(:tag_id)
  end

  def self.matched_policies_dataset(project_id, subject_id, actions = nil, object_id = nil)
    dataset = DB[:access_control_entry]
      .where(project_id:)
      .where(Sequel.or([subject_id, recursive_tag_query(:subject, subject_id)].map { [:subject_id, _1] }))

    if actions
      actions = Array(actions).map { ActionType::NAME_MAP.fetch(_1) }
      dataset = dataset.where(Sequel.or([nil, actions, recursive_tag_query(:action, actions, project_id:)].map { [:action_id, _1] }))
    end

    if object_id
      # Recognize UUID format
      if /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(object_id)
        ubid = UBID.from_uuidish(object_id).to_s
      else
        ubid = object_id
        # Otherwise, should be valid UBID, raise error if not
        object_id = UBID.parse(object_id).to_uuid
      end

      if (klass = UBID.class_for_ubid(ubid))
        # This checks that the object being authorized is actually related to the project.
        # This is probably a redundant check, but I think it helps to have defense in depth
        # here.  This makes it so if a project-level restriction is missed before the
        # authorization call, this will make authorization fail.
        dataset = klass.filter_authorize_dataset(dataset, object_id)
      end

      dataset = dataset.where(Sequel.or([nil, object_id, recursive_tag_query(:object, object_id)].map { [:object_id, _1] }))
    end

    dataset
  end

  def self.matched_policies(project_id, subject_id, actions = nil, object_id = nil)
    matched_policies_dataset(project_id, subject_id, actions, object_id).all
  end

  def self.dataset_authorize(dataset, project_id, subject_id, actions)
    # We can't use "id" column directly, because it's ambiguous in big joined queries.
    # We need to determine table of id explicitly.
    from = dataset.opts[:from].first

    ds = DB[:object_ids]
      .with_recursive(:object_ids,
        Authorization.matched_policies_dataset(project_id, subject_id, actions).select(:object_id, 0),
        DB[:applied_object_tag].join(:object_ids, object_id: :tag_id)
          .select(Sequel[:applied_object_tag][:object_id], Sequel[:level] + 1)
          .where { level < Config.recursive_tag_limit },
        args: [:object_id, :level]).select(:object_id)

    # If the model includes HyperTagMethods, look in access_tag.
    # This is a temporary change while we populate the project_id
    # columns for the related models.  After population, only
    # the Account model will use access_tag.
    project_id_match = if dataset.model < HyperTagMethods
      DB[:access_tag].select(:project_id).where(hyper_tag_id: Sequel[from][:id])
    else
      Sequel[from][:project_id]
    end

    if dataset.model == ObjectTag
      # Authorization for accessing ObjectTag itself is done by providing the metatag for the object.
      # Convert metatag id returned from the applied_object_tag lookup into tag ids, so that the correct
      # object tags will be found.  Convert non-metatag ids into UUIDs that would be invalid UBIDs,
      # preventing them from matching any existing ObjectTag instances.  This makes it so that users
      # authorized to manage members of the tag are not automatically authorized to manage the tag itself.
      ds = ds
        .select(Sequel.cast(:object_id, String))
        .from_self
        .select {
        Sequel.join([
          substr(:object_id, 0, 18),
          Sequel.case({"2" => "0"}, "3", substr(:object_id, 18, 1)),
          substr(:object_id, 19, 18)
        ]).cast(:uuid).as(:object_id)
      }
    end

    dataset.where(Sequel.|(
      # Allow where there is a specific entry for the object,
      {Sequel[from][:id] => ds},
      # or where the action is allowed for all objects in the project,
      (ds.where(object_id: nil).exists &
        # and the object is related to the project (either with a matching project_id,
        # or where there is a hyper tag from the object to the project.
        {project_id => project_id_match})
    ))
  end

  module HyperTagMethods
    module ClassMethods
      def filter_authorize_dataset(dataset, object_id)
        dataset.where(project_id: DB[:access_tag].where(hyper_tag_id: object_id).select(:project_id))
      end
    end

    def self.included(base)
      base.class_eval do
        extend ClassMethods
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

      # Temporary code to ensure that project_id column already set,
      # except for Account which doesn't have the column
      # :nocov:
      case self
      when Account
        nil
      when Project
        raise "Should already have id column set" unless id == project.id
      else
        raise "Should already have project_id column set" unless project_id == project.id
      end
      # :nocov:

      AccessTag.create_with_id(
        project_id: project.id,
        name: hyper_tag_name(project),
        hyper_tag_id: id,
        hyper_tag_table: self.class.table_name
      )
    end

    def dissociate_with_project(project)
      return if project.nil?
      hyper_tag(project).destroy
    end
  end
end
