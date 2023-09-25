# frozen_string_literal: true

class Prog::DownloadBootImage < Prog::Base
  subject_is :sshable, :vm_host

  def image_name
    @image_name ||= frame.fetch("image_name")
  end

  def custom_url
    @custom_url ||= frame.fetch("custom_url")
  end

  label def start
    vm_host.update(allocation_state: "draining")
    hop_wait_draining
  end

  label def wait_draining
    unless vm_host.vms.empty?
      nap 15
    end
    sshable.cmd("sudo rm -f /var/storage/images/#{image_name.shellescape}.raw")
    hop_download
  end

  label def download
    case sshable.cmd("common/bin/daemonizer --check download_#{image_name.shellescape}")
    when "Succeeded"
      hop_learn_storage
    when "NotStarted"
      sshable.cmd("common/bin/daemonizer 'host/bin/download-boot-image #{image_name.shellescape} #{custom_url.shellescape}' download_#{image_name.shellescape}")
    when "Failed"
      puts "#{vm_host} Failed to download '#{image_name}' image"
    end

    nap 15
  end

  label def learn_storage
    bud Prog::LearnStorage
    hop_wait_learn_storage
  end

  label def wait_learn_storage
    reap.each do |st|
      case st.prog
      when "LearnStorage"
        kwargs = {
          total_storage_gib: st.exitval.fetch("total_storage_gib"),
          available_storage_gib: st.exitval.fetch("available_storage_gib")
        }

        vm_host.update(**kwargs)
      end
    end

    if leaf?
      hop_activate_host
    end
    donate
  end

  label def activate_host
    vm_host.update(allocation_state: "accepting")

    pop "#{image_name} downloaded"
  end
end
