# frozen_string_literal: true

module ErrorCodes
  class BaseError < StandardError
    def initialize(error)
      @error = error
    end

    def to_s
      @error
    end
  end

  class DependencyError < BaseError; end

  class PostgresPrimaryError < BaseError; end
end
