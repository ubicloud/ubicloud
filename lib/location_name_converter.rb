# frozen_string_literal: true

module LocationNameConverter
  def self.to_internal_name(display_name)
    Location.where(display_name:).get(:name)
  end

  def self.to_visible_internal_name(display_name)
    Location.where(display_name:, visible: true).get(:name)
  end

  def self.to_display_name(internal_name)
    Location.where(name: internal_name).get(:display_name)
  end
end
