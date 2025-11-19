# frozen_string_literal: true

class Prog::Vm::Aws::Nexus < Prog::Base
  subject_is :vm

  def before_run
    when_destroy_set? do
      unless ["destroy", "wait_aws_vm_destroyed"].include? strand.label
        vm.active_billing_records.each(&:finalize)
        vm.assigned_vm_address&.active_billing_record&.finalize
        register_deadline(nil, 5 * 60)
        hop_destroy
      end
    end
  end

  label def start_aws
    nap 1 unless vm.nics.all? { |nic| nic.strand.label == "wait" }
    bud Prog::Aws::Instance, {"subject_id" => vm.id, "alternative_families" => frame["alternative_families"]}, :start
    hop_wait_aws_vm_started
  end

  label def wait_aws_vm_started
    reap(:wait_sshable, nap: 3)
  end

  label def wait_sshable
    unless vm.update_firewall_rules_set?
      vm.incr_update_firewall_rules
      # This is the first time we get into this state and we know that
      # wait_sshable will take definitely more than 6 seconds. So, we nap here
      # to reduce the amount of load on the control plane unnecessarily.
      nap 6
    end
    addr = vm.ip4
    hop_create_billing_record unless addr

    begin
      Socket.tcp(addr.to_s, 22, connect_timeout: 1) {}
    rescue SystemCallError
      nap 1
    end

    hop_create_billing_record
  end

  label def create_billing_record
    vm.update(display_state: "running", provisioned_at: Time.now)

    Clog.emit("vm provisioned") { [vm, {provision: {vm_ubid: vm.ubid, instance_id: vm.aws_instance.instance_id, duration: (Time.now - vm.allocated_at).round(3)}}] }

    project = vm.project
    strand.stack[-1]["create_billing_record_done"] = true
    strand.modified!(:stack)
    hop_wait unless project.billable

    BillingRecord.create(
      project_id: project.id,
      resource_id: vm.id,
      resource_name: vm.name,
      billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
      amount: vm.vcpus
    )

    hop_wait
  end

  label def wait
    when_update_firewall_rules_set? do
      register_deadline("wait", 5 * 60)
      hop_update_firewall_rules
    end

    nap 6 * 60 * 60
  end

  label def update_firewall_rules
    if retval&.dig("msg") == "firewall rule is added"
      hop_wait
    end

    decr_update_firewall_rules
    push vm.update_firewall_rules_prog, {}, :update_firewall_rules
  end

  label def prevent_destroy
    register_deadline("destroy", 24 * 60 * 60)
    nap 30
  end

  label def destroy
    decr_destroy

    when_prevent_destroy_set? do
      Clog.emit("Destroy prevented by the semaphore")
      hop_prevent_destroy
    end

    vm.update(display_state: "deleting")
    Semaphore.incr(strand.children_dataset.where(prog: "Aws::Instance").select(:id), "destroy")
    bud Prog::Aws::Instance, {"subject_id" => vm.id}, :destroy
    hop_wait_aws_vm_destroyed
  end

  label def wait_aws_vm_destroyed
    reap(nap: 10) do
      final_clean_up
      pop "vm deleted"
    end
  end

  def final_clean_up
    vm.nics.map do |nic|
      nic.update(vm_id: nil)
      nic.incr_destroy
    end
    vm.destroy
  end
end
