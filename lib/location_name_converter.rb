# frozen_string_literal: true

module LocationNameConverter
  def self.to_internal_name(display_name)
    Option::LOCATIONS.find { _1.display_name == display_name }&.name
  end

  def self.to_display_name(internal_name)
    Option::LOCATIONS.find { _1.name == internal_name }&.display_name
  end
end
