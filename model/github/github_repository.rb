# frozen_string_literal: true

require_relative "../../model"

class GithubRepository < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, key: :installation_id, class: :GithubInstallation
  one_to_many :runners, key: :repository_id, class: :GithubRunner

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy
end
