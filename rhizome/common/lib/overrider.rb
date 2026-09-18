# frozen_string_literal: true

# Loads deployment-specific overrides for rhizome code, the guest-side
# counterpart to lib/overrider.rb. Prog::InstallRhizome replaces this file with
# one that requires overrider_enabled when support_rhizome_overrides is set.
module Overrider
  def self.load(file, root: nil)
  end
end
