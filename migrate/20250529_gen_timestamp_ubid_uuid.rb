# frozen_string_literal: true

Sequel.migration do
  up do
    # This function generates a timestamp-based UUID,
    # that is in valid UBID format.  It is passed the UBID type as an integer.
    # You can get the type integer using `UBID.to_base32_n(prefix)`
    # (e.g. `UBID.to_base32_n("vm") # => 884`).
    #
    # This could be used in the future as the DEFAULT value for uuid primary
    # keys for tables that use timestamp ubids.
    run <<~SQL
      CREATE FUNCTION gen_timestamp_ubid_uuid(ubid_type int) RETURNS uuid AS $$
      DECLARE
        r0 bigint;
        r1 int;
        r2 int;
        r3 bigint;

        p1 text;
        p2 text;
      BEGIN
        -- 48 bit timestamp milliseconds
        r0 = floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
        -- 4 bit version + 2 bit random + 10 bit type
        r1 = ((32 + floor(4 * random()::numeric)::integer) << 10) | ubid_type;
        --  2 bit variant + 2 bit random
        r2 = 8 + floor(4 * random()::numeric)::integer;
        -- 60 bit random
        r3 = floor(1152921504606846976 * random()::numeric)::bigint;

        p1 = lpad(to_hex(r0), 12, '0');
        p2 = lpad(to_hex(r3), 15, '0');

        RETURN (substr(p1, 1, 8) || '-' || substr(p1, 9, 4) || '-' || lpad(to_hex(r1), 4, '0') || '-' || to_hex(r2) || substr(p2, 1, 3) || '-' || substr(p2, 4, 12))::uuid;
      END
      $$ LANGUAGE plpgsql;
    SQL
  end

  down do
    run "DROP FUNCTION gen_timestamp_ubid_uuid(int)"
  end
end
