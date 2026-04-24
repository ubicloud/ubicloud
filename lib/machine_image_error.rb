# frozen_string_literal: true

# Lets MachineImage progs flag invalid input/state with a 400 response,
# so callers don't have to pre-check the same conditions.
class MachineImageError < CloverError
  def initialize(message)
    super(400, "InvalidRequest", message)
  end
end
