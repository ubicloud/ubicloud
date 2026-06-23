# frozen_string_literal: true

class Hosting::ProviderApis
  def self.for(provider)
    Object.const_get("Hosting::#{provider.provider_name.capitalize}Apis").new(provider)
  rescue NameError
    raise "unknown provider #{provider.provider_name}"
  end

  def initialize(provider)
    @provider = provider
  end
end
