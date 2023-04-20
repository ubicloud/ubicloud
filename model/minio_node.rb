# frozen_string_literal: true

require_relative "../model"

class MinioNode < Sequel::Model
    one_to_one :vm, key: :id
    one_to_one :strand, key: :id
    one_to_one :sshable, key: :id


end
