# frozen_string_literal: true

module Ubicloud
  module BaseCheckExists
    # Check whether the model instance exists. Returns nil if it does not exist.
    def check_exists
      _info(missing: nil)
    end
  end

  module BaseLazyId
    # The model instance's id, which will be a 26 character string. If it isn't
    # available, this will make a request to retrieve it.
    def id
      @values.fetch(:id) do
        _info
        @values[:id]
      end
    end
  end

  module BaseDestroy
    # Destroy the model instance.
    def destroy
      adapter.delete(_path)
    end
  end

  module BaseList
    # Return a list of model instances.
    def list(adapter)
      adapter.get(fragment)[:items].map { new(adapter, it) }
    end
  end

  # Ubicloud::Model is the abstract base class for model classes.  There is a
  # separate model class for each primary object type in Ubicloud's API.
  class BaseModel
    class << self
      # A hash of associations for the model.  This is used by instances
      # to automatically wrap returned objects in model instances.
      attr_reader :associations

      # The path fragment for this model in the Ubicloud API.
      attr_reader :fragment

      # A regexp for valid id format for instances of this model.
      attr_reader :id_regexp

      # Resolve associations.  This is called after all models have been loaded.
      # This approach is taken to avoid the need for autoload or const_get.
      def resolve_associations # :nodoc:
        @associations = @association_block&.call || {}
      end

      private

      # Used by models to set defaults for parameters.  Overrides the _create_params
      # method using the given block.  The block should mutate the parameter hash.
      def set_create_param_defaults
        singleton_class.send(:private, define_singleton_method(:_create_params) do |params|
          params = params.dup || {}
          yield params
          params
        end)
      end

      # The parameters to use when creating an object.  Uses only the given parameters
      # by default.
      def _create_params(params)
        params
      end

      # Register the assocation block that will be used for resolving associations.
      def set_associations(&block)
        @association_block = block
      end

      # Create methods for each of the model's columns (unless the method is already defined).
      # These methods will fully populate the object if the related key is not already present
      # in the model.
      def set_columns(*columns)
        columns.each do |column|
          next if method_defined?(column)

          define_method(column) do
            @values.fetch(column) do
              _info
              @values[column]
            end
          end
        end
      end

      # Create methods for columns that should always be in values and should never need to
      # be lazy loaded.
      def set_direct_columns(*columns)
        columns.each do |column|
          define_method(column) do
            @values[column]
          end
        end
      end

      # Use the given regexp to set the valid id_regexp format for the model.
      def set_prefix(prefix)
        @id_regexp = %r{\A#{prefix}[a-tv-z0-9]{24}\z}
      end

      # Set the path fragment that this model uses in the Ubicloud API.
      def set_fragment(fragment)
        @fragment = fragment
      end
    end

    # Return the adapter used for this model instance.  Each model instance is tied to a
    # specific adapter, and requests to the Ubicloud API are made through the adapter.
    attr_reader :adapter

    # A hash of values for the model instance.
    attr_reader :values
    alias_method :to_h, :values

    # Return the value of a specific key for the model instance.
    def [](key)
      @values[key]
    end

    # The model's id, which will be a 26 character string.  This will load the
    # id from Ubicloud if the model instance doesn't currently store the id
    # (such as when it was initialized with a location and name).
    def id
      @values[:id]
    end

    # Show the class name and values hash.
    def inspect
      "#<#{self.class.name} #{@values.inspect}>"
    end

    private

    def _info(missing: :raise)
      if (hash = adapter.get(_path, missing:))
        merge_into_values(hash)
      end
    end

    # Raise an error if the given string contains a slash.  This is used for strings
    # used as path fragments when making requests, to raise an error before issuing
    # an HTTP request in the case where you know the path would not be valid.
    def check_no_slash(string, error_message)
      raise Error, error_message if string.include?("/")
    end

    # If the given id is not already a string, call id on it to get a string.
    # This is used in methods that can accept either a model instance or an id.
    def to_id(id)
      (String === id) ? id : id.id
    end

    # For each of the model's associations, convert the related entry in the values
    # hash to an associated object.
    def check_associations
      values = @values

      self.class.associations.each do |key, klass|
        next unless (value = values[key])

        values[key] = if value.is_a?(Array)
          value.map do
            convert_to_association(it, klass)
          end
        else
          convert_to_association(value, klass)
        end
      end
    end

    # Convert the given value to an instance of the given klass.
    def convert_to_association(value, klass)
      case value
      when Hash, klass.id_regexp
        klass.new(adapter, value)
      when String
        # The object is given by name and not by id, assume that
        # it must be in the same location as the receiver.
        klass.new(adapter, "#{location}/#{value}")
      else
        value
      end
    end

    # Merge the given values into the values hash, and convert any entries in
    # the values hash to associated objects.
    def merge_into_values(values)
      @values.merge!(values)
      check_associations
      self
    end
  end
end
