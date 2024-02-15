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
