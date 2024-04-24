# frozen_string_literal: true

class CloverError < StandardError
  attr_reader :code, :title, :message, :details
  def initialize(code, title, message, details = nil)
    @code = code
    @title = title
    @message = message
    @details = details

    super(message)
  end
end

# Add here instead of routes/project.rb as it will be used by other APIs as well
# TODO: Remove the comment once another API use it
class DependencyError < CloverError
  def initialize(message)
    super(409, "Dependency Error", message)
  end
end
