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

class DependencyError < CloverError
  def initialize(message)
    super(409, "DependencyError", message)
  end
end

class NoContentError < CloverError
  def initialize
    super(204, "NoContent", nil)
  end
end

class NotFoundError < CloverError
  def initialize(message = "Sorry, we couldn’t find the resource you’re looking for.")
    super(404, "ResourceNotFound", message)
  end
end

class InvalidRequestError < CloverError
  def initialize(message)
    super(400, "InvalidRequest", message)
  end
end
