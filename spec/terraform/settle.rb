# frozen_string_literal: true

# For each table whose rows the API reports as pending until a prog runs,
# settle_<table> does what the control plane would have done by the time
# the object is at rest. The harness runs no progs, so it calls the hook
# after the API accepts any change, including a DELETE, if the object's
# row still exists.
module TerraformHarness::Settle
  module_function

  # A DELETE leaves a load balancer in place until LoadBalancerNexus
  # destroys it, together with its VM memberships and ports.
  def settle_load_balancer(lb)
    lb.destroy if lb.destroy_set?
  end

  # The API creates a subnet at rest, and a DELETE leaves it deleting until
  # SubnetNexus destroys it.
  def settle_private_subnet(ps)
    ps.destroy if ps.destroy_set?
  end
end
