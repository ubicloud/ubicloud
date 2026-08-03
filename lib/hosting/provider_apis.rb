# frozen_string_literal: true

class Hosting::ProviderApis
  def self.for(provider)
    # A dash suffix picks the org within a provider kind; the API class is
    # shared per kind, so it resolves from the prefix alone.
    Object.const_get("Hosting::#{provider.provider_name.split("-").first.capitalize}Apis").new(provider)
  rescue NameError
    raise "unknown provider #{provider.provider_name}"
  end

  def initialize(provider)
    @provider = provider
  end
end
