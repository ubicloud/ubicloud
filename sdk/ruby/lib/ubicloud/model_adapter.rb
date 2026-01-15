# frozen_string_literal: true

module Ubicloud
  # Ubicloud::ModelAdapter instances represents a model class
  # that is tied to a adapter.  Methods called on instances
  # of this class are forwarded to the related model, with
  # the adapter as the first argument.
  class ModelAdapter
    def initialize(model, adapter)
      @model = model
      @adapter = adapter
    end

    # Return the id regexp for the model.
    def id_regexp
      @model.id_regexp
    end

    # Forward methods to the model class, but include the
    # adapter as the first argument.
    def method_missing(meth, ...)
      @model.public_send(meth, @adapter, ...)
    end

    # Respond to the method if the model class responds to it.
    def respond_to_missing?(...)
      @model.respond_to?(...)
    end
  end
end
