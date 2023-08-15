# frozen_string_literal: true

require_relative "../model"

class Invoice < Sequel::Model
  include ResourceMethods

  def path
    "/invoice/#{ubid}"
  end

  def name
    begin_time.strftime("%B %Y")
  end
end
