# frozen_string_literal: true

module AccessControlModelTag
  def self.included(model)
    model.class_eval do
      base = name.delete_suffix("Tag").downcase
      table = :"applied_#{base}_tag"
      column = :"#{base}_id"

      define_method(:applied_table) { table }
      define_method(:applied_column) { column }
      define_method(:"add_#{base}") { add_member(it) }
      define_method(:path) { "/user/access-control/tag/#{base}/#{ubid}" }
    end
  end

  def applied_dataset
    DB[applied_table]
  end

  def add_member(member_id)
    applied_dataset.insert(:tag_id => id, applied_column => member_id)
  end

  def member_ids
    applied_dataset.where(tag_id: id).select_map(applied_column)
  end

  def add_members(member_ids)
    applied_dataset.import([:tag_id, applied_column], member_ids.map { [id, it] })
  end

  def remove_members(member_ids)
    applied_dataset.where(:tag_id => id, applied_column => member_ids).delete
  end

  def currently_included_in
    DB[:tag]
      .with_recursive(:tag,
        DB[applied_table].where(applied_column => id).select(:tag_id, 0),
        DB[applied_table].join(:tag, tag_id: applied_column)
          .select(Sequel[applied_table][:tag_id], Sequel[:level] + 1)
          .where { level < Config.recursive_tag_limit },
        args: [:tag_id, :level])
      .select_map(:tag_id)
  end

  def check_members_to_add(to_add)
    issues = []

    current_members = member_ids

    # Do not allow tag to include itself (prevent simple recursion)
    if to_add.include?(id)
      to_add.delete(id)
      issues << "cannot include tag in itself"
    end

    # Remove current members so there are no duplicates
    size = to_add.size
    to_add -= current_members
    if to_add.size != size
      issues << "#{size - to_add.size} members already in tag"
    end

    # Check that current tag is not included already in one of the tags
    # being added directly or indirectly (prevent complex recursion)
    size = to_add.size
    to_add -= currently_included_in
    if to_add.size != size
      issues << "#{size - to_add.size} members already include tag directly or indirectly"
    end

    proposed_additions = {}
    to_add.each { proposed_additions[it] = nil }
    UBID.resolve_map(proposed_additions)

    to_add = []
    # Only allow valid members into the tag
    proposed_additions.each_value do
      if is_a?(SubjectTag) && it.is_a?(SubjectTag) && it.name == "Admin"
        issues << "cannot include Admin subject tag in another tag"
        next
      end
      to_add << it if it && self.class.valid_member?(project_id, it)
    end
    if proposed_additions.size != to_add.size
      issues << "#{proposed_additions.size - to_add.size} members not valid"
    end

    to_add.map!(&:id)
    to_add.uniq!
    [to_add, issues]
  end

  def before_destroy
    meta_cond = {object_id: respond_to?(:metatag_uuid) ? metatag_uuid : id}
    applied_dataset.where(tag_id: id).or(applied_column => id).delete
    DB[:applied_object_tag].where(meta_cond).delete
    AccessControlEntry.where(applied_column => id).or(meta_cond).destroy
    super
  end

  def validate
    validates_format(%r{\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\z}i, :name, message: "must only include ASCII letters, numbers, and dashes, and must start and end with an ASCII letter or number")
    super
  end
end
