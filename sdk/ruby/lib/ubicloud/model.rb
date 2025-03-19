# frozen_string_literal: true

module Ubicloud
  class Model
    class << self
      alias_method :[], :new

      attr_reader :associations

      attr_reader :fragment

      attr_reader :id_regexp

      def create(adapter, location, name, params = nil)
        new(adapter, adapter.post("location/#{location}/#{fragment}/#{name}", _create_params(params)))
      end

      def list(adapter, location: nil)
        path = if location
          raise Error, "invalid location: #{location.inspect}" if location.include?("/")
          "location/#{location}/#{fragment}"
        else
          fragment
        end

        adapter.get(path)[:items].map { new(adapter, _1) }
      end

      def resolve_associations
        @associations = @association_block&.call || {}
      end

      private

      def set_create_param_defaults
        singleton_class.send(:private, define_singleton_method(:_create_params) do |params|
          params = params.dup
          yield params
          params
        end)
      end

      def _create_params(params)
        params
      end

      def set_associations(&block)
        @association_block = block
      end

      def set_columns(*columns)
        columns.each do |column|
          next if method_defined?(column)
          define_method(column) do
            info unless @values.has_key?(column)
            @values[column]
          end
        end
      end

      def set_prefix(prefix)
        @id_regexp = %r{\A#{prefix}[a-tv-z0-9]{24}\z}
      end

      def set_fragment(fragment)
        @fragment = fragment
      end
    end

    attr_reader :adapter
    attr_reader :values

    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        @values = if self.class.id_regexp.match?(values)
          {id: values}
        else
          location, name, extra = values.split("/", 3)
          raise Error, "invalid #{self.class} name: #{values.inspect}" if extra
          {location:, name:}
        end
      when Hash
        @values = {}
        merge_into_values(values)
      else
        raise Error, "unsupported value initializing #{self.class}: #{values.inspect}"
      end
    end

    def to_h
      @values
    end

    def [](key)
      @values[key]
    end

    def path(rest = "")
      "location/#{location}/#{self.class.fragment}/#{name}#{rest}"
    end

    def destroy
      adapter.delete(path)
    end

    def id
      unless (id = @values[:id])
        info
        id = @values[:id]
      end

      id
    end

    def location
      unless (location = @values[:location])
        load_object_info_from_id
        location = @values[:location]
      end

      location
    end

    def name
      unless (name = @values[:name])
        load_object_info_from_id
        name = @values[:name]
      end

      name
    end

    def info
      merge_into_values(adapter.get("location/#{location}/#{self.class.fragment}/#{name}"))
    end

    def inspect
      "#<#{self.class.name} #{@values.inspect}>"
    end

    private

    def check_associations
      values = @values

      self.class.associations.each do |key, klass|
        next unless (value = values[key])

        values[key] = if value.is_a?(Array)
          value.map do
            convert_to_association(_1, klass)
          end
        else
          convert_to_association(value, klass)
        end
      end
    end

    def convert_to_association(value, klass)
      case value
      when Hash, klass.id_regexp
        klass.new(adapter, value)
      when String
        klass.new(adapter, "#{location}/#{value}")
      else
        value
      end
    end

    def load_object_info_from_id
      hash = adapter.get("object-info/#{id}")
      hash.delete("type")
      merge_into_values(hash)
    end

    def merge_into_values(values)
      @values.merge!(values)
      check_associations
      self
    end
  end
end

Dir.open(File.join(__dir__, "model")) do |dir|
  dir.each_child do |file|
    if file.end_with?(".rb")
      require_relative "model/#{file}"
    end
  end
end

Ubicloud::Model.subclasses.each(&:resolve_associations)
