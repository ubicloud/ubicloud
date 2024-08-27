#  frozen_string_literal: true

require_relative "../model"

class ProjectInvitation < Sequel::Model
  many_to_one :project
end

ProjectInvitation.unrestrict_primary_key
