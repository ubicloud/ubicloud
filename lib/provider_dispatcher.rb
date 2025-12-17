# frozen_string_literal: true

module ProviderDispatcher
  PROVIDERS = %i[Aws Metal].freeze

  def self.configure(model, file)
    dir, file = File.split(file)
    methods = {}
    PROVIDERS.each do |const|
      subdir = const.to_s.downcase
      require File.join(dir, const.to_s.downcase, file)
      implementation = model.const_get(const)
      model.include implementation

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
      aws_meth = :"aws_#{meth}"
      metal_meth = :"metal_#{meth}"
      model.define_method(meth) do |*a, **kw, &b|
        if aws?
          send(aws_meth, *a, **kw, &b)
        else
          send(metal_meth, *a, **kw, &b)
        end
      end
    end
  end

  module InstanceMethods
    def aws?
      location.aws?
    end
  end
end
