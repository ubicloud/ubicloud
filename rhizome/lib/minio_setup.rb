#!/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/common"

class MinioSetup
  def initialize
  end

  def setup
    r "wget 'https://ubicloud-minio.s3.dualstack.eu-central-1.amazonaws.com/minio_20230413030807.0.0_amd64.deb' -P /home/rhizome/"
    r "apt install /home/rhizome/minio_20230413030807.0.0_amd64.deb"
    # the storage size needs to be configurable
    r "dd if=/dev/zero of=/foo.img bs=3M count=1024"
    # need to find the device name properly
    r "losetup /dev/loop10 /foo.img"
    # need to decide on a filesystem
    r "mkfs.xfs /dev/loop10"
    r "mkdir -p /storage/minio"
    r "groupadd -r minio-user"
    r "useradd -M -r -g minio-user minio-user"
    r "mount /dev/loop10 /storage"
    r "chown -R minio-user:minio-user /storage"
  end

  def configure(node_name)
    r "touch /etc/default/minio"
    r "chown -R minio-user:minio-user /etc/default/minio"
    # this is extremely ugly and doesn't get the node count, but it's a start
    r "echo 'MINIO_VOLUMES=\"http://#{node_name.split(".")[0][0..-2]}{1...2}.#{node_name.split(".")[1..].join(".")}:9000/storage/minio\"' >> /etc/default/minio"
    r "echo 'MINIO_OPTS=\"--console-address :9001\"' >> /etc/default/minio"
    # need to make these configurable
    r "echo 'MINIO_ROOT_USER=\"minioadmin\"' >> /etc/default/minio"
    r "echo 'MINIO_ROOT_PASSWORD=\"minioadmin\"' >> /etc/default/minio"
    # read this from the cluster
    r "echo 'MINIO_SECRET_KEY=\"12345678\"' >> /etc/default/minio"
    r "echo 'MINIO_ACCESS_KEY=\"minioadmin\"' >> /etc/default/minio"
  end
end