# frozen_string_literal: true

module Ubicloud
  class MachineImage < Model
    set_prefix "m1"

    set_fragment "machine-image"

    set_columns :id, :name, :description, :state, :location, :arch, :size_gib, :encrypted, :compression, :visible, :source_vm_id, :created_at
  end
end
