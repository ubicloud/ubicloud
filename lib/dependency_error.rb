# frozen_string_literal: true

class DependencyError < CloverError
  def initialize(message)
    super(409, "DependencyError", message)
  end
end
