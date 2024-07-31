#  frozen_string_literal: true

require_relative "../model"

class CertsLoadBalancers < Sequel::Model
  many_to_one :cert
  include ResourceMethods

  def destroy
    DB.transaction do
      cert.incr_destroy
      super
    end
  end
end
