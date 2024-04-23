# frozen_string_literal: true

class CloverError < StandardError
  attr_reader :code, :type, :message, :details
  def initialize(code, type, message, details = nil)
    @code = code
    @type = type
    @message = message
    @details = details

    super(message)
  end
end

# Add here instead of routes/project.rb as it will be used by other APIs as well
# TODO: Remove the comment once another API use it
class DependencyError < CloverError
  def initialize(message)
    super(409, "DependencyError", message)
  end
end
