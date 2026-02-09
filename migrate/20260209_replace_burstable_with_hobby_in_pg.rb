# frozen_string_literal: true

Sequel.migration do
  up do
    from(:postgres_resource)
      .where(Sequel.like(:target_vm_size, "burstable-%"))
      .update(target_vm_size: Sequel.expr { replace(target_vm_size, "burstable-", "hobby-") })
  end

  down do
    from(:postgres_resource)
      .where(Sequel.like(:target_vm_size, "hobby-%"))
      .update(target_vm_size: Sequel.expr { replace(target_vm_size, "hobby-", "burstable-") })
  end
end
