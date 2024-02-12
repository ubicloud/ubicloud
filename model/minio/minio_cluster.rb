# frozen_string_literal: true

require_relative "../../model"

class MinioCluster < Sequel::Model
  one_to_many :pools, key: :cluster_id, class: :MinioPool do |ds|
    ds.order(:start_index)
  end
  many_through_many :servers, [[:minio_pool, :cluster_id, :id], [:minio_server, :minio_pool_id, :id]], class: :MinioServer do |ds|
    ds.order(:index)
  end
  one_to_one :strand, key: :id
  many_to_one :private_subnet, key: :private_subnet_id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy, :reconfigure

  plugin :column_encryption do |enc|
    enc.column :admin_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/minio-cluster/#{name}"
  end

  def generate_etc_hosts_entry
    servers.map do |server|
      "#{server.private_ipv4_address} #{server.hostname}"
    end.join("\n")
  end

  def storage_size_gib
    pools.sum(&:storage_size_gib)
  end

  def server_count
    pools.sum(&:server_count)
  end

  def drive_count
    pools.sum(&:drive_count)
  end

  def ip4_urls
    servers.map(&:ip4_url)
  end

  def single_instance_single_drive?
    server_count == 1 && drive_count == 1
  end

  def single_instance_multi_drive?
    server_count == 1 && drive_count > 1
  end

  def hostname
    "#{name}.#{Config.minio_host_name}"
  end

  def url
    dns_zone ? "https://#{hostname}:9000" : nil
  end

  def dns_zone
    @dns_zone ||= DnsZone.where(project_id: Config.minio_service_project_id, name: Config.minio_host_name).first
  end

  def root_certs
    root_cert_1.to_s + root_cert_2.to_s
  end

  def self.redacted_columns
    super + [:root_cert_1, :root_cert_2]
  end
end
