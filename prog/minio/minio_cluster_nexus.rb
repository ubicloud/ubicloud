# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Minio::MinioClusterNexus < Prog::Base
  subject_is :minio_cluster

  frame_reader :initial_cert_id
  frame_accessor :refresh_cert_id, :current_cert_id

  def self.assemble(project_id, cluster_name, location_id, admin_user,
    storage_size_gib, pool_count, server_count, drive_count, vm_size)
    unless Project[project_id]
      fail "No existing project"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    Validation.validate_vm_size(vm_size, "x64")
    Validation.validate_name(cluster_name)
    Validation.validate_minio_username(admin_user)
    per_pool_server_count, per_pool_drive_count, per_pool_storage_size = Validation.validate_minio_setup(storage_size_gib:, pool_count:, server_count:, drive_count:)

    DB.transaction do
      ubid = MinioCluster.generate_ubid

      dns_zone = DnsZone.first(project_id: Config.minio_service_project_id, name: Config.minio_host_name)
      use_publicly_signed_certificates = Config.acme_email && dns_zone

      unless use_publicly_signed_certificates
        root_cert_1, root_cert_key_1 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
        root_cert_2, root_cert_key_2 = Util.create_root_certificate(common_name: "#{ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
      end

      subnet_st = Prog::Vnet::SubnetNexus.assemble(
        Config.minio_service_project_id,
        name: "#{cluster_name}-subnet",
        location_id: location.id,
      )
      minio_cluster = MinioCluster.create(
        name: cluster_name,
        location_id: location.id,
        admin_user:,
        admin_password: SecureRandom.urlsafe_base64(15),
        private_subnet_id: subnet_st.id,
        root_cert_1:,
        root_cert_key_1:,
        root_cert_2:,
        root_cert_key_2:,
        project_id:,
      ) { it.id = ubid.to_uuid }

      strand_args = {}
      if use_publicly_signed_certificates
        cert_st = Prog::Vnet::CertNexus.assemble(
          minio_cluster.hostname,
          dns_zone.id,
          waiting_strand_id: minio_cluster.id,
        )
        strand_args = {stack: [{"initial_cert_id" => cert_st.id, "current_cert_id" => cert_st.id}]}
      end

      pool_count.times do |i|
        start_index = i * per_pool_server_count
        Prog::Minio::MinioPoolNexus.assemble(minio_cluster.id, start_index, per_pool_server_count, per_pool_drive_count, per_pool_storage_size, vm_size)
      end

      Strand.create_with_id(minio_cluster, prog: "Minio::MinioClusterNexus", label: "wait_certificates", **strand_args)
    end
  end

  label def wait_certificates
    register_deadline("wait", 30 * 60)

    if minio_cluster.uses_publicly_signed_certificates? && initial_cert_id
      wait_for_public_cert("initial_cert_id")
      minio_cluster.save_changes
    end

    hop_wait_pools
  end

  label def wait_pools
    register_deadline("wait", 10 * 60)
    if minio_cluster.pools.all? { it.strand.label == "wait" }
      MinioServer.incr_restart(server_ids_dataset)
      hop_wait
    end
    nap 5
  end

  label def wait
    if minio_cluster.certificate_last_checked_at < Time.now - 60 * 60 * 24 * (minio_cluster.uses_publicly_signed_certificates? ? 7 : 30)
      register_deadline("wait", 30 * 60)
      hop_refresh_certificates
    end

    when_refresh_certificates_set? do
      register_deadline("wait", 30 * 60)
      hop_refresh_certificates
    end

    when_switch_to_public_certs_set? do
      register_deadline("wait", 30 * 60)
      hop_switch_to_public_certs
    end

    when_reconfigure_set? do
      hop_reconfigure
    end

    nap 60 * 60 * 24
  end

  label def refresh_certificates
    decr_refresh_certificates

    if minio_cluster.uses_publicly_signed_certificates?
      minio_cluster.certificate_last_checked_at = Time.now
      minio_cluster.save_changes

      if OpenSSL::X509::Certificate.new(minio_cluster.server_cert).not_after < Time.now + 60 * 60 * 24 * 21
        self.current_cert_id = self.refresh_cert_id = Prog::Vnet::CertNexus.assemble(
          minio_cluster.hostname,
          minio_cluster.dns_zone.id,
          waiting_strand_id: minio_cluster.id,
        ).id
        hop_wait_refresh_public_cert
      end

      hop_wait
    end

    if OpenSSL::X509::Certificate.new(minio_cluster.root_cert_1).not_after < Time.now + 60 * 60 * 24 * 30 * 5
      minio_cluster.root_cert_1, minio_cluster.root_cert_key_1 = minio_cluster.root_cert_2, minio_cluster.root_cert_key_2
      minio_cluster.root_cert_2, minio_cluster.root_cert_key_2 = Util.create_root_certificate(common_name: "#{minio_cluster.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
      MinioServer.incr_reconfigure(server_ids_dataset)
    end

    minio_cluster.certificate_last_checked_at = Time.now
    minio_cluster.save_changes

    hop_wait
  end

  label def wait_refresh_public_cert
    wait_for_public_cert("refresh_cert_id")
    minio_cluster.save_changes
    MinioServer.incr_reconfigure(server_ids_dataset)
    hop_wait
  end

  label def reconfigure
    decr_reconfigure
    MinioServer.incr_reconfigure(server_ids_dataset)
    MinioServer.incr_restart(server_ids_dataset)
    hop_wait
  end

  label def switch_to_public_certs
    decr_switch_to_public_certs

    hop_wait if minio_cluster.uses_publicly_signed_certificates?

    unless Config.acme_email && minio_cluster.dns_zone
      Clog.emit("Cannot switch minio cluster to publicly signed certificates: ACME or DNS zone not configured", {cannot_switch_minio_to_public_certs: {ubid: minio_cluster.ubid}})
      hop_wait
    end

    self.current_cert_id = Prog::Vnet::CertNexus.assemble(
      minio_cluster.hostname,
      minio_cluster.dns_zone.id,
      waiting_strand_id: minio_cluster.id,
    ).id
    hop_wait_switch_to_public_certs
  end

  label def wait_switch_to_public_certs
    wait_public_cert(current_cert_id)
    minio_cluster.certificate_last_checked_at = Time.now
    minio_cluster.update(root_cert_1: nil, root_cert_key_1: nil, root_cert_2: nil, root_cert_key_2: nil)
    MinioServer.incr_switch_to_public_certs(server_ids_dataset)
    hop_wait
  end

  label def destroy
    register_deadline(nil, 10 * 60)
    decr_destroy
    minio_cluster.pools.each(&:incr_destroy)
    hop_wait_pools_destroyed
  end

  label def wait_pools_destroyed
    nap 10 unless minio_cluster.pools.empty?
    minio_cluster.private_subnet.firewalls.map(&:destroy)
    minio_cluster.private_subnet.incr_destroy
    Cert.incr_destroy(current_cert_id) if current_cert_id
    minio_cluster.destroy

    pop "destroyed"
  end

  def server_ids_dataset
    minio_cluster.servers_dataset.select(Sequel[:minio_server][:id])
  end

  def wait_public_cert(cert_id)
    cert = Cert.with_pk!(cert_id)
    nap(10 * 60) unless cert.cert

    minio_cluster.server_cert = cert.cert
    minio_cluster.server_cert_key = OpenSSL::PKey::EC.new(cert.csr_key).to_pem
  end

  def wait_for_public_cert(frame_key)
    wait_public_cert(send(frame_key))
    delete_from_stack(frame_key)
  end
end
