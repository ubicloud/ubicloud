# frozen_string_literal: true

class Prog::DownloadBootImage < Prog::Base
  subject_is :sshable, :vm_host

  def image_name
    @image_name ||= frame.fetch("image_name")
  end

  def custom_url
    @custom_url ||= frame["custom_url"]
  end

  def blob_storage_client
    @blob_storage_client ||= Minio::Client.new(
      endpoint: Config.ubicloud_images_blob_storage_endpoint,
      access_key: Config.ubicloud_images_blob_storage_access_key,
      secret_key: Config.ubicloud_images_blob_storage_secret_key,
      ssl_ca_file_data: Config.ubicloud_images_blob_storage_certs
    )
  end

  label def start
    vm_host.update(allocation_state: "draining")
    hop_wait_draining
  end

  label def wait_draining
    nap 15 unless vm_host.vms_dataset.where(boot_image: image_name).empty?

    sshable.cmd("sudo rm -f /var/storage/images/#{image_name.shellescape}.raw")
    hop_download
  end

  label def download
    case sshable.cmd("common/bin/daemonizer --check download_#{image_name.shellescape}")
    when "Succeeded"
      sshable.cmd("common/bin/daemonizer --clean download_#{image_name.shellescape}")
      hop_learn_storage
    when "NotStarted"
      url = custom_url || blob_storage_client.get_presigned_url("GET", Config.ubicloud_images_bucket_name, "#{image_name}-#{vm_host.arch}.raw", 60 * 60).to_s
      sshable.cmd("common/bin/daemonizer 'host/bin/download-boot-image #{image_name.shellescape} #{url.shellescape}' #{("download_" + image_name).shellescape}", stdin: Config.ubicloud_images_blob_storage_certs)
    when "Failed"
      fail "Failed to download '#{image_name}' image on #{vm_host}"
    end

    nap 15
  end

  label def learn_storage
    bud Prog::LearnStorage
    hop_wait_learn_storage
  end

  label def wait_learn_storage
    reap
    if leaf?
      pop "#{image_name} downloaded"
    end
    donate
  end
end
