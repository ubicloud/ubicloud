# frozen_string_literal: true

module LocationNameConverter
  def self.to_internal_name(display_name)
    Location[display_name:]&.name
  end

  def self.to_display_name(internal_name)
    Location[name: internal_name]&.display_name
  end
end
