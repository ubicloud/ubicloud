# frozen_string_literal: true

require_relative "../../common/lib/util"

class MinioConfigure
  CERTS_DIR = "/home/minio-user/.minio/certs"

  def initialize(config)
    fail "need minio_config as argument" unless (@minio_config = config["minio_config"])
    fail "need hosts as argument" unless (@hosts = config["hosts"])

    @cert = config["cert"]
    @cert_key = config["cert_key"]
    @ca_bundle = config["ca_bundle"]
    @peer_cert = config["peer_cert"]
    @peer_cert_key = config["peer_cert_key"]
  end

  def run
    safe_write_to_file("/etc/default/minio", @minio_config)
    safe_write_to_file("/etc/hosts", @hosts)
    r "sudo chown -R minio-user:minio-user /etc/default/minio"

    # MinIO reuses pooled connections for the shard reads a heal issues, and each of
    # those goes idle between reads. Letting the kernel reset the congestion window
    # to its initial value every time held a heal to a few MB/s per connection.
    safe_write_to_file("/etc/sysctl.d/70-minio.conf", "net.ipv4.tcp_slow_start_after_idle=0\n")
    r "sudo sysctl --quiet --load /etc/sysctl.d/70-minio.conf"

    write_certs if present?(@cert) && present?(@cert_key)
  end

  private

  def write_certs
    r "sudo mkdir -p :dir", dir: "#{CERTS_DIR}/CAs"
    safe_write_to_file("#{CERTS_DIR}/public.crt", @cert)
    safe_write_to_file("#{CERTS_DIR}/private.key", @cert_key)
    if present?(@ca_bundle)
      safe_write_to_file("#{CERTS_DIR}/CAs/public.crt", @ca_bundle)
    end
    if present?(@peer_cert) && present?(@peer_cert_key)
      r "sudo mkdir -p :dir", dir: "#{CERTS_DIR}/peer"
      safe_write_to_file("#{CERTS_DIR}/peer/public.crt", @peer_cert)
      safe_write_to_file("#{CERTS_DIR}/peer/private.key", @peer_cert_key)
    end
    r "sudo chown -R minio-user:minio-user :dir", dir: CERTS_DIR
  end

  def present?(value)
    value && !value.empty?
  end
end
