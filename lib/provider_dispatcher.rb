# frozen_string_literal: true

module ProviderDispatcher
  PROVIDERS = %i[Aws Metal Gcp].freeze

  def self.configure(model, file)
    dir, file = File.split(file)
    methods = {}
    available_providers = []
    PROVIDERS.each do |const|
      subdir = const.to_s.downcase
      provider_file = File.join(dir, subdir, file)
      # :nocov:
      next unless File.exist?(provider_file)
      # :nocov:

      load provider_file
      implementation = model.const_get(const)
      model.include implementation
      available_providers << const

      prefix = subdir + "_"
      methods[prefix] = implementation.private_instance_methods.filter_map do
        it.to_s.delete_prefix(prefix) if it.start_with?(prefix)
      end
    end

    all_meths = methods.values.flatten.sort.uniq
    methods.each do |prefix, meths|
      # :nocov:
      unless meths.sort == all_meths
        raise "Not all methods implemented by all providers: prefix: #{prefix}, missing methods: #{(all_meths - meths).join(", ")}"
      end
      # :nocov:
    end

    all_meths.each do |meth|
      model.define_method(meth) do |*a, **kw, &b|
        send(:"#{provider_name}_#{meth}", *a, **kw, &b)
      end
    end
  end

  module InstanceMethods
    def aws?
      location.aws?
    end

    def provider_name
      location.provider_name
    end
  end
end
