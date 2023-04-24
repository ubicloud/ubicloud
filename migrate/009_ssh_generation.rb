# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table :sshable do
      # Rename to be more verbose, a short name that uses higher level
      # abstractions is provided.  A long name deters using the wrong
      # method.
      rename_column :private_key, :raw_private_key_1

      # Make room for a second key for rotation.
      add_column :raw_private_key_2, :text, collate: '"C"'

      # After consideration for Sshable Vms, relaxing the non-nullable
      # host name constraint is the smallest evil to deal with a
      # common situation: we need to store a private key, and send a
      # public key somewhere, e.g. to a new Vm that will run
      # cloud-init, but do not yet know the network address or host it
      # will be assigned.
      #
      # Using the Strand stack is not advisable for secret data, as
      # it's not encrypted.  And decomposing Sshable to avoid nulls by
      # separating out the keys from the host name is overwrought.  A
      # nullable host squares the circle even if it's a little weird.
      set_column_allow_null :host
    end
  end
end
