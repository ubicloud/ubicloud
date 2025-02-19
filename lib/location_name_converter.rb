# frozen_string_literal: true

module LocationNameConverter
  def self.to_internal_name(display_name)
    DB[:provider_location].find { _1[:display_name] == display_name }[:internal_name]
  end

  def self.to_display_name(internal_name)
    DB[:provider_location].find { _1[:internal_name] == internal_name }[:display_name]
  end
end
