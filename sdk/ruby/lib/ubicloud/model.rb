# frozen_string_literal: true

require_relative "base_model"

module Ubicloud
  # Ubicloud::Model is the abstract base class for model classes.  There is a
  # separate model class for each primary object type in Ubicloud's API.
  class Model < BaseModel
    class << self
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
    end

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

    # Rename the object to the given name.
    def rename_to(name)
      merge_into_values(adapter.post(_path("/rename"), name:))
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
        _info
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

    # Check whether the current instance exists in Ubicloud.  Returns nil if the
    # object does not exist.
    def check_exists
      @values[:name] ? _info(missing: nil) : load_object_info_from_id(missing: nil)
    end

    private

    # Given only the object's id, find the location and name of the object
    # and merge them into the values hash.
    def load_object_info_from_id(missing: :raise)
      if (hash = adapter.get("object-info/#{values[:id]}", missing:))
        hash.delete("type")
        merge_into_values(hash)
      end
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
Dir.glob("model/*.rb", base: __dir__) do |file|
  require_relative file
end
(Ubicloud::BaseModel.subclasses + Ubicloud::Model.subclasses - [Ubicloud::Model]).each(&:resolve_associations)
