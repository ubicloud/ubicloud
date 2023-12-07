# frozen_string_literal: true

class ResourceAccessor
  # TODOBV: Don't like having them as module, though I don't want
  # them to be implemented on a single class...
  extend PrivateSubnetAccessor
  extend VmAccessor
end

# Following are assumed to be exist globally
# current_user
# project
# project_data (sec)
# project_permissions (sec)
# policy

# prices --> can be different (not a problem)
