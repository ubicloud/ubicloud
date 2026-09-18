# frozen_string_literal: true

# An override lives at <folder>/override/<path of the file it patches>, so
# postgres/override/lib/postgres_setup.rb patches postgres/lib/postgres_setup.rb.
# A file supporting overrides calls Overrider.load(__FILE__) after the class it
# defines, which is why an override may read that class and prepend to it
# without naming its superclass.
module Overrider
  # The folder InstallRhizome untars into, which is this file's grandparent.
  # Resolved, because __FILE__ at a call site may not be.
  ROOT = File.realpath(File.dirname(File.dirname(__dir__)))

  def self.load(file, root: ROOT)
    root = File.realpath(root)
    directory, _, path = File.realpath(file).delete_prefix("#{root}/").partition("/")
    override = File.join(root, directory, "override", path)
    require override if File.exist?(override)
  end
end
