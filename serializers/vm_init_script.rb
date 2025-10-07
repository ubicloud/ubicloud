# frozen_string_literal: true

class Serializers::VmInitScript < Serializers::Base
  def self.serialize_internal(vm_init_script, options = {})
    h = {
      id: vm_init_script.ubid,
      name: vm_init_script.name
    }

    h[:script] = vm_init_script.script if options[:detailed]

    h
  end
end
