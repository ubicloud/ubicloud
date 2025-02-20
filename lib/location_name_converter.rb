# frozen_string_literal: true

module LocationNameConverter
  def self.to_internal_name(display_name)
    ProviderLocation[display_name: display_name]&.internal_name
  end

  def self.to_display_name(internal_name)
    ProviderLocation[internal_name: internal_name]&.display_name
  end
end
