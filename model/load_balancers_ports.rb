#  frozen_string_literal: true

require_relative "../model"

class LoadBalancersVms < Sequel::Model
  many_to_one :load_balancer
  include ResourceMethods
  include HealthMonitorMethods
end
