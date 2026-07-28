# frozen_string_literal: true

# The seed migrations 20251008_add_ist_location and 20260519_add_ps_location
# inserted these locations with hand-picked uuids that are not valid location
# ubids. Replace them with valid ones. Targets are fixed (not random) so every
# environment converges on the same ids and this migration is reversible.
#
# These locations are in active use, so location.id is referenced by real rows
# (vm, vm_host, private_subnet, firewall, ...). We repoint the location and every
# FK child in a SINGLE statement via writable CTEs: the NO ACTION foreign keys
# are only checked at end of statement, by which point parent and children are
# all consistent. This needs no ON UPDATE CASCADE and no DDL, so it takes only
# row locks -- no table locks. Each location is also managed by a LocationNexus
# strand that SHARES its id (subject resolved via strand.id); that strand has no
# FK references (verified), so a plain update keeps it in lockstep.
Sequel.migration do
  remap = {
    "8701c4ed-bd32-4a49-9fd0-b552c7d6d73f" => "07a7d115-de9d-8020-abd3-01125d3e82d9", # tr-ist-u1     (100ykx25eykp1nf9g24jx7t1dj)
    "f03eed1b-2d59-4509-a2b1-98fe7021948a" => "af577d23-ca47-8420-8b4e-405f20483b20", # tr-ist-u1-tom (10nxbqt8ya8y2hd740qs090xj0)
    "3ef7ec20-990f-442e-9d52-c314e65ab34f" => "735adb21-1e87-8c20-8dee-c5dce8ac1ced", # us-west-u1-ps (10edddp88ygy6hqqcbq78ngeet)
  }

  # location.id itself plus every column that FK-references it. Kept explicit so
  # the set is auditable; must stay in sync with the foreign keys on location.
  location_columns = [
    [:location, :id],
    [:firewall, :location_id],
    [:gcp_vpc, :location_id],
    [:inference_endpoint, :location_id],
    [:inference_router, :location_id],
    [:kubernetes_cluster, :location_id],
    [:kubernetes_etcd_backup, :location_id],
    [:location_az, :location_id],
    [:location_credential_aws, :id],
    [:location_credential_gcp, :id],
    [:machine_image, :location_id],
    [:machine_image_store, :location_id],
    [:minio_cluster, :location_id],
    [:parseable_resource, :location_id],
    [:postgres_resource, :location_id],
    [:postgres_timeline, :location_id],
    [:private_subnet, :location_id],
    [:victoria_metrics_resource, :location_id],
    [:vm, :location_id],
    [:vm_host, :location_id],
    [:vm_pool, :location_id],
  ]

  replace = ->(db, mapping) do
    mapping.each do |old_id, new_id|
      ds = db.select(1)
      location_columns.each_with_index do |(table, column), i|
        ds = ds.with(:"u#{i}", db[table].where(column => old_id).with_sql(:update_sql, column => new_id))
      end
      ds.all

      db.from(:strand).where(id: old_id).update(id: new_id)
    end
  end

  up { replace.call(self, remap) }
  down { replace.call(self, remap.invert) }
end
