# frozen_string_literal: true

module Overrider
  Config = Data.define(:override_dir, :base_dir, :vendor_dir) do
    def load_overrides(klass)
      return unless (class_name = klass.name)
      namespace, _, class_name = class_name.rpartition("::")
      namespace = namespace.empty? ? Object : Object.const_get(namespace)
      defined_file = File.realpath(namespace.const_source_location(class_name)[0])

      # gems are installed under vendor_dir in CI with bundler-cache true
      return unless defined_file.start_with?(base_dir) && !defined_file.start_with?(vendor_dir)
      load_file = File.join(override_dir, defined_file.delete_prefix(base_dir))

      return unless File.exist?(load_file)
      load(load_file)
      klass.prepend(klass::PrependMethods) if defined?(klass::PrependMethods)
      klass.singleton_class.prepend(klass::PrependClassMethods) if defined?(klass::PrependClassMethods)
    end
  end

  def self.setup_overrides(klass, override_dir, base_dir: File.dirname(__dir__))
    base_dir = "#{File.realpath(base_dir)}/"
    klass.extend(SubclassHandler)
    config = Config.new(File.realpath(override_dir), base_dir, "#{base_dir}vendor/")
    config.load_overrides(klass)
    klass.const_set(:OverriderConfig, config)
  end

  module SubclassHandler
    private

    def inherited(subclass)
      super
      self::OverriderConfig.load_overrides(subclass)
    end
  end
end
