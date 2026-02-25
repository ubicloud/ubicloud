# frozen_string_literal: true

module Ubicloud
  class MachineImage < Model
    set_prefix "m1"

    set_fragment "machine-image"

    set_columns :id, :name, :description, :state, :size_gib, :arch, :encrypted, :compression, :visible, :version, :active, :location, :source_vm_id, :created_at
  end
end
