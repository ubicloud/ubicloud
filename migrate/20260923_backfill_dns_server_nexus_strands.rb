# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      INSERT INTO strand (id, prog, label)
      SELECT id, 'DnsZone::DnsServerNexus', 'wait'
      FROM dns_server
      ON CONFLICT (id) DO NOTHING;
    SQL
  end

  down do
    ids = from(:strand).where(prog: "DnsZone::DnsServerNexus").select_map(:id)
    from(:semaphore).where(strand_id: ids).delete
    from(:strand).where(id: ids).delete
  end
end
