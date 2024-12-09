# frozen_string_literal: true

module AccessControlModelTag
  def self.included(model)
    model.class_eval do
      base = name.delete_suffix("Tag").downcase
      table = :"applied_#{base}_tag"
      column = :"#{base}_id"

      define_method(:applied_table) { table }
      define_method(:applied_column) { column }
      define_method(:"add_#{base}") { add_member(_1) }
    end
  end

  def applied_dataset
    DB[applied_table]
  end

  def add_member(member_id)
    applied_dataset.insert(:tag_id => id, applied_column => member_id)
  end
end
