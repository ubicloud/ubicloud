# frozen_string_literal: true

class CloverError < StandardError
  attr_reader :code, :type, :details, :retry_after
  def initialize(code, type, message, details = nil, retry_after: nil)
    @code = code
    @type = type
    @details = details
    @retry_after = retry_after

    super(message)
  end
end
