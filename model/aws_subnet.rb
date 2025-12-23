# frozen_string_literal: true

require_relative "../model"

class AwsSubnet < Sequel::Model
  many_to_one :private_subnet_aws_resource

  plugin ResourceMethods
end
