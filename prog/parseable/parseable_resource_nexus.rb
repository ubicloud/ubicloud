# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Parseable::ParseableResourceNexus < Prog::Base
  subject_is :parseable_resource

  def self.assemble(project_id:, name:, location_id:, admin_user:, vm_size:, storage_size_gib:)
    Validation.validate_name(name)

    DB.transaction do
      ubid = ParseableResource.generate_ubid
      root_cert_1, root_cert_key_1 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
      root_cert_2, root_cert_key_2 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)

      parseable_resource = ParseableResource.create(
        name:,
        location_id:,
        admin_user:,
        admin_password: SecureRandom.urlsafe_base64(15),
        root_cert_1:,
        root_cert_key_1:,
        root_cert_2:,
        root_cert_key_2:,
        access_key: SecureRandom.hex(16),
        secret_key: SecureRandom.hex(32),
        target_vm_size: vm_size,
        target_storage_size_gib: storage_size_gib,
        project_id:,
      )

      firewall = Firewall.create(name: "#{parseable_resource.ubid}-firewall", location_id:, description: "Parseable default firewall", project_id: Config.parseable_service_project_id)

      private_subnet_id = Prog::Vnet::SubnetNexus.assemble(Config.parseable_service_project_id, name: "#{parseable_resource.ubid}-subnet", location_id:, firewall_id: firewall.id).id
      parseable_resource.update(private_subnet_id:)

      firewall.replace_firewall_rules(
        Config.control_plane_outbound_cidrs.map { {cidr: it, port_range: Sequel.pg_range(22..22)} } + [
          {cidr: "0.0.0.0/0", port_range: Sequel.pg_range(8000..8000)},
          {cidr: "::/0", port_range: Sequel.pg_range(8000..8000)},
        ],
      )

      Strand.create_with_id(parseable_resource, prog: "Parseable::ParseableResourceNexus", label: "configure_blob_storage")
    end
  end

  label def configure_blob_storage
    register_deadline("wait_servers", 10 * 60)

    blob_storage = parseable_resource.blob_storage
    unless blob_storage&.strand&.label == "wait"
      # No MinIO available yet in this location; retry shortly
      nap 30
    end

    admin_client = parseable_resource.blob_storage_admin_client
    admin_client.admin_add_user(parseable_resource.access_key, parseable_resource.secret_key)
    admin_client.admin_policy_add(parseable_resource.ubid, parseable_resource.blob_storage_policy)
    admin_client.admin_policy_set(parseable_resource.ubid, parseable_resource.access_key)

    parseable_resource.blob_storage_client.create_bucket(parseable_resource.bucket_name)
    parseable_resource.blob_storage_client.set_lifecycle_policy(
      parseable_resource.bucket_name,
      parseable_resource.ubid,
      ParseableResource::LOG_BUCKET_EXPIRATION_DAYS,
    )

    Prog::Parseable::ParseableServerNexus.assemble(parseable_resource)

    hop_wait_servers
  end

  label def wait_servers
    register_deadline("wait", 10 * 60)

    if Strand.where(id: parseable_resource.servers_dataset.select(:id)).exclude(label: "wait").empty?
      hop_wait
    end

    nap 10
  end

  label def wait
    if parseable_resource.certificate_last_checked_at < Time.now - 60 * 60 * 24 * 30 # ~1 month
      hop_refresh_certificates
    end

    when_reconfigure_set? do
      hop_reconfigure
    end

    # Nap for 1 month, to check for certs.
    nap 60 * 60 * 24 * 30
  end

  label def refresh_certificates
    if OpenSSL::X509::Certificate.new(parseable_resource.root_cert_1).not_after < Time.now + 60 * 60 * 24 * 30 * 5
      parseable_resource.root_cert_1, parseable_resource.root_cert_key_1 = parseable_resource.root_cert_2, parseable_resource.root_cert_key_2
      parseable_resource.root_cert_2, parseable_resource.root_cert_key_2 = Util.create_root_certificate(common_name: "#{parseable_resource.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
      Semaphore.incr(parseable_resource.servers_dataset.select(:id), "reconfigure")
    end

    parseable_resource.certificate_last_checked_at = Time.now
    parseable_resource.save_changes

    hop_wait
  end

  label def reconfigure
    decr_reconfigure
    server_ids = parseable_resource.servers_dataset.select(:id)
    Semaphore.incr(server_ids, "reconfigure")
    Semaphore.incr(server_ids, "restart")
    hop_wait
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy

    if parseable_resource.blob_storage && parseable_resource.access_key
      begin
        parseable_resource.blob_storage_admin_client.admin_remove_user(parseable_resource.access_key)
        parseable_resource.blob_storage_admin_client.admin_policy_remove(parseable_resource.ubid)
      rescue => ex
        Clog.emit("Failed to clean up MinIO user for parseable resource", Util.exception_to_hash(ex))
      end
    end

    firewall = parseable_resource.private_subnet.firewalls_dataset.first(name: "#{parseable_resource.ubid}-firewall")
    firewall&.destroy
    parseable_resource.private_subnet.incr_destroy

    Semaphore.incr(parseable_resource.servers_dataset.select(:id), "destroy")
    hop_wait_servers_destroyed
  end

  label def wait_servers_destroyed
    nap 10 unless parseable_resource.servers_dataset.empty?
    parseable_resource.destroy

    pop "destroyed"
  end
end
