# frozen_string_literal: true

module Validation
  class ValidationFailed < StandardError
    attr_reader :errors
    def initialize(errors)
      @errors = errors
      super("Validation failed for some fields")
    end
  end

  # Allow DNS compatible names
  # - Max length 63
  # - Only lowercase letters, numbers, and hyphens
  # - Not start or end with a hyphen
  # Adapted from https://stackoverflow.com/a/7933253
  # Do not allow uppercase letters to not deal with case sensitivity
  ALLOWED_NAME_PATTERN = '\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\z'

  def self.validate_name(name)
    msg = "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."
    fail ValidationFailed.new({name: msg}) unless name.match(ALLOWED_NAME_PATTERN)
  end
end
