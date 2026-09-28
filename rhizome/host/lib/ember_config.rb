# frozen_string_literal: true

module EmberConfig
  GUEST_MAC = "02:5b:0c:00:00:02"
  GUEST_IP6 = "fd00:b1c:5b0c::2"
  GUEST_ROUTER_IP6 = "fd00:b1c:5b0c::1"
  GUEST_ROUTER_IP4 = "10.255.255.1"

  VM_ROOT = "/vm"
  EMBER_ROOT = "/var/storage/ember"
  TEMPLATE_ROOT = "#{EMBER_ROOT}/templates"
  STATE_DIR = "/var/lib/ember"

  def self.slot_name(index)
    format("emslot%04d", index)
  end

  def self.slot_dir(index)
    File.join(VM_ROOT, slot_name(index))
  end

  def self.template_dir(template_id)
    File.join(TEMPLATE_ROOT, template_id)
  end
end
