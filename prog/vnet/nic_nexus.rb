# frozen_string_literal: true

class Prog::Vnet::NicNexus < Prog::Base
  subject_is :nic

  def self.assemble(private_subnet_id, name: nil, ipv6_addr: nil, ipv4_addr: nil, exclude_availability_zones: [], availability_zone: nil)
    unless (subnet = PrivateSubnet[private_subnet_id])
      fail "Given subnet doesn't exist with the id #{private_subnet_id}"
    end

    ubid = Nic.generate_ubid
    id = ubid.to_uuid
    name ||= Nic.ubid_to_name(ubid)

    ipv6_addr ||= subnet.random_private_ipv6.to_s
    ipv4_addr ||= random_private_ipv4(subnet) || subnet.random_private_ipv4
    ipv4_addr = ipv4_addr.to_s

    DB.transaction do
      Nic.create_with_id(id, private_ipv6: ipv6_addr, private_ipv4: ipv4_addr, mac: gen_mac, name:, private_subnet_id:)
      label = if subnet.location.aws?
        "create_aws_nic"
      else
        "wait_allocation"
      end
      Strand.create_with_id(id, prog: "Vnet::NicNexus", label:, stack: [{"exclude_availability_zones" => exclude_availability_zones, "availability_zone" => availability_zone}])
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy if strand.label != "destroy"
    end
  end

  label def create_aws_nic
    nap 10 unless nic.private_subnet.strand.label == "wait"
    NicAwsResource.create_with_id(nic.id)
    bud Prog::Aws::Nic, {"subject_id" => nic.id, "exclude_availability_zones" => frame["exclude_availability_zones"], "availability_zone" => frame["availability_zone"]}, :create_subnet
    hop_wait_aws_nic_created
  end

  label def wait_aws_nic_created
    reap(:wait, nap: 10)
  end

  label def wait_allocation
    when_vm_allocated_set? do
      hop_wait_setup
    end
    nap 5
  end

  label def wait_setup
    decr_vm_allocated
    when_setup_nic_set? do
      DB.transaction do
        decr_setup_nic
        nic.private_subnet.incr_add_new_nic
      end
    end
    when_start_rekey_set? do
      hop_start_rekey
    end
    nap 5
  end

  label def wait
    if nic.private_subnet.location.aws?
      nic.semaphores.each(&:destroy)
      nap 60 * 60 * 24 * 365
    end

    when_repopulate_set? do
      nic.private_subnet.incr_refresh_keys
      decr_repopulate
    end

    when_start_rekey_set? do
      hop_start_rekey
    end

    nap 6 * 60 * 60
  end

  label def start_rekey
    decr_start_rekey

    if retval&.dig("msg") == "inbound_setup is complete"
      hop_wait_rekey_outbound_trigger
    end

    push Prog::Vnet::RekeyNicTunnel, {}, :setup_inbound
  end

  label def wait_rekey_outbound_trigger
    if retval&.dig("msg") == "outbound_setup is complete"
      hop_wait_rekey_old_state_drop_trigger
    end

    when_trigger_outbound_update_set? do
      decr_trigger_outbound_update
      push Prog::Vnet::RekeyNicTunnel, {}, :setup_outbound
    end

    nap 5
  end

  label def wait_rekey_old_state_drop_trigger
    if retval&.dig("msg")&.include?("drop_old_state is complete")
      hop_wait
    end

    when_old_state_drop_trigger_set? do
      decr_old_state_drop_trigger
      push Prog::Vnet::RekeyNicTunnel, {}, :drop_old_state
    end

    nap 5
  end

  label def destroy
    if nic.vm
      Clog.emit("Cannot destroy nic with active vm, first clean up the attached resources") { nic }
      nap 5
    end

    decr_destroy

    if nic.private_subnet.location.aws?
      strand.children.select { it.prog == "Aws::Nic" }.each { it.destroy }
      bud Prog::Aws::Nic, {"subject_id" => nic.id}, :destroy
      hop_wait_aws_nic_destroyed
    end

    nic.private_subnet.incr_refresh_keys
    nic.destroy

    pop "nic deleted"
  end

  label def wait_aws_nic_destroyed
    reap(nap: 10) do
      nic.private_subnet.incr_refresh_keys
      nic.destroy
      pop "nic deleted"
    end
  end
  # Generate a MAC with the "local" (generated, non-manufacturer) bit
  # set and the multicast bit cleared in the first octet.
  #
  # Accuracy here is not a formality: otherwise assigning a ipv6 link
  # local address errors out.
  def self.gen_mac
    ([rand(256) & 0xFE | 0x02] + Array.new(5) { rand(256) }).map {
      "%0.2X" % it
    }.join(":").downcase
  end

  def self.random_private_ipv4(private_subnet)
    random_subnet = private_subnet.random_private_ipv4
    return random_subnet unless private_subnet.location.aws?

    random_subnet.nth_subnet(32, 4)
  end
end
