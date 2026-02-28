# frozen_string_literal: true

Sequel.migration do
  up do
    # Fix UBID type codes to use canonical Crockford base32 characters.
    # "i" is non-canonical (maps to "1"), so types using "i" get
    # incorrect prefixes when encoded.
    #
    # it(58) -> nt(698), ai(321) -> a0(320), mi(641) -> m0(640)
    # ri(769) -> r1(769) — same value, no change needed

    run "ALTER TABLE init_script_tag ALTER COLUMN id SET DEFAULT gen_random_ubid_uuid(698)"
    run "ALTER TABLE app_process_init ALTER COLUMN id SET DEFAULT gen_random_ubid_uuid(320)"
    run "ALTER TABLE app_member_init ALTER COLUMN id SET DEFAULT gen_random_ubid_uuid(640)"
  end

  down do
    run "ALTER TABLE init_script_tag ALTER COLUMN id SET DEFAULT gen_random_ubid_uuid(58)"
    run "ALTER TABLE app_process_init ALTER COLUMN id SET DEFAULT gen_random_ubid_uuid(321)"
    run "ALTER TABLE app_member_init ALTER COLUMN id SET DEFAULT gen_random_ubid_uuid(641)"
  end
end
