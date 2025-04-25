# frozen_string_literal: true

module Ubicloud
  # Ubicloud::Model is the abstract base class for model classes.  There is a
  # separate model class for each primary object type in Ubicloud's API.
  class Model
    class << self
      # A hash of associations for the model.  This is used by instances
      # to automatically wrap returned objects in model instances.
      attr_reader :associations

      # The path fragment for this model in the Ubicloud API.
      attr_reader :fragment

      # A regexp for valid id format for instances of this model.
      attr_reader :id_regexp

      # Return a new model instance for the given values, tied to the
      # related adapter, if the model instance exists and is accessible.
      # Return nil if the model instance does not exist or is not
      # accessible.  +values+ can be:
      #
      # * a string in a valid id format for the model
      # * a string in location/name format
      # * a hash of values (must contain either :id key or :location and :name keys)
      def [](adapter, values)
        new(adapter, values).check_exists
      end

      # Create a new model object in Ubicloud with the given location, name, and params.
      def create(adapter, location:, name:, **params)
        new(adapter, adapter.post("location/#{location}/#{fragment}/#{name}", _create_params(params)))
      end

      # Return an array of all model instances you have access to in Ubicloud. If the
      # +location+ keyword argument is given, only return model instances for that location.
      def list(adapter, location: nil)
        path = if location
          raise Error, "invalid location: #{location.inspect}" if location.include?("/")
          "location/#{location}/#{fragment}"
        else
          fragment
        end

        adapter.get(path)[:items].map { new(adapter, it) }
      end

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
            info unless @values.has_key?(column)
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

    # Create a new model instance, which should represent an object that already exists
    # in Ubicloud. +values+ can be:
    #
    # * a string in a valid id format for the model
    # * a string in location/name format
    # * a hash with symbol keys (must contain either :id key or :location and :name keys)
    def initialize(adapter, values)
      @adapter = adapter

      case values
      when String
        @values = if self.class.id_regexp.match?(values)
          {id: values}
        else
          location, name, extra = values.split("/", 3)
          raise Error, "invalid #{self.class.fragment} location/name: #{values.inspect}" if extra || !name
          {location:, name:}
        end
      when Hash
        if !values[:id] && !(values[:location] && values[:name])
          raise Error, "hash must have :id key or :location and :name keys"
        end
        @values = {}
        merge_into_values(values)
      else
        raise Error, "unsupported value initializing #{self.class}: #{values.inspect}"
      end
    end

    # Return hash of data for this model instance.
    def to_h
      @values
    end

    # Return the value of a specific key for the model instance.
    def [](key)
      @values[key]
    end

    # Destroy the given model instance in Ubicloud.  It is not possible to restore
    # objects that have been destroyed, so only use this if you are sure you want
    # to destroy the object.
    def destroy
      adapter.delete(_path)
    end

    # The model's id, which will be a 26 character string.  This will load the
    # id from Ubicloud if the model instance doesn't currently store the id
    # (such as when it was initialized with a location and name).
    def id
      unless (id = @values[:id])
        info
        id = @values[:id]
      end

      id
    end

    # The model's location, as a string.  This will load the location from Ubicloud
    # if the model instance does not currently store it (such as when it was
    # initialized with an id).
    def location
      unless (location = @values[:location])
        load_object_info_from_id
        location = @values[:location]
      end

      location
    end

    # The model's name.  This will load the name from Ubicloud if the model instance
    # does not currently store it (such as when it was initialized with an id).
    def name
      unless (name = @values[:name])
        load_object_info_from_id
        name = @values[:name]
      end

      name
    end

    # Fully populate the model instance by making a request to the Ubicloud API.
    # This can also be used to refresh an already populated instance.
    def info
      _info
    end

    # Show the class name and values hash.
    def inspect
      "#<#{self.class.name} #{@values.inspect}>"
    end

    # Check whether the current instance exists in Ubicloud.  Returns nil if the
    # object does not exist.
    def check_exists
      @values[:name] ? _info(missing: nil) : load_object_info_from_id(missing: nil)
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

    # Given only the object's id, find the location and name of the object
    # and merge them into the values hash.
    def load_object_info_from_id(missing: :raise)
      if (hash = adapter.get("object-info/#{values[:id]}", missing:))
        hash.delete("type")
        merge_into_values(hash)
      end
    end

    # Merge the given values into the values hash, and convert any entries in
    # the values hash to associated objects.
    def merge_into_values(values)
      @values.merge!(values)
      check_associations
      self
    end

    # The path to use for requests for the model instance.  If +rest+ is given,
    # it is appended to the path.
    def _path(rest = "")
      "location/#{location}/#{self.class.fragment}/#{name}#{rest}"
    end
  end
end

# Require each model subclass, and then resolve associations after
# all subclasses have been loaded.
Dir.open(File.join(__dir__, "model")) do |dir|
  dir.each_child do |file|
    if file.end_with?(".rb")
      require_relative "model/#{file}"
    end
  end
end
Ubicloud::Model.subclasses.each(&:resolve_associations)
