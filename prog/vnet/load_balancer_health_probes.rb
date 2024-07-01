# frozen_string_literal: true

class Prog::Vnet::LoadBalancerHealthProbes < Prog::Base
  subject_is :vm

  def load_balancer
    @load_balancer ||= LoadBalancer[frame.fetch("load_balancer_id")]
  end

  label def health_probe
    response_code = nil
    begin
      endpoint = "#{vm.nics.first.private_ipv4.network}:#{load_balancer.dst_port}#{load_balancer.health_check_endpoint}"
      response_code = vm.vm_host.sshable.cmd("sudo ip netns exec #{vm.inhost_name} curl --max-time #{load_balancer.health_check_timeout} --silent --output /dev/null --write-out '%{http_code}' #{endpoint}")
    rescue Sshable::SshError
      response_code = "500"
    end

    vm_state, vm_state_last_changed = DB[:load_balancers_vms].where(load_balancer_id: load_balancer.id, vm_id: vm.id).get([:state, :state_last_changed])
    threshold = (response_code == "200") ? load_balancer.health_check_up_threshold : load_balancer.health_check_down_threshold
    health_check = (response_code == "200") ? "up" : "down"
    if health_check != vm_state && vm_state_last_changed < Time.now - (load_balancer.health_check_interval * threshold)
      DB[:load_balancers_vms].where(load_balancer_id: load_balancer.id, vm_id: vm.id).update(state: health_check, state_last_changed: Time.now)
      load_balancer.incr_update_load_balancer
    end

    nap load_balancer.health_check_interval
  end
end
