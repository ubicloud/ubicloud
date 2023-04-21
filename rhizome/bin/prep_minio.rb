#!/bin/env ruby
# frozen_string_literal: true
require_relative "../lib/common"


r "wget 'https://ubicloud-minio.s3.dualstack.eu-central-1.amazonaws.com/minio_20230413030807.0.0_amd64.deb' -P /home/rhizome/"
r "apt install /home/rhizome/minio_20230413030807.0.0_amd64.deb"
r "dd if=/dev/zero of=/foo.img bs=3M count=1024"
r "losetup /dev/loop10 /foo.img"
r "mkfs.xfs /dev/loop10"
r "mkdir -p /storage/minio"
r "groupadd -r minio-user"
r "useradd -M -r -g minio-user minio-user"
r "mount /dev/loop10 /storage"
r "chown -R minio-user:minio-user /storage"