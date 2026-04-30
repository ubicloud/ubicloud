# frozen_string_literal: true

require "securerandom"
require_relative "kubernetes_client"
require_relative "node_service"
require_relative "service_helper"

module Csi
  # Owns the lifecycle of CSIStorageCapacity objects for our driver.
  #
  # Why we manage them ourselves instead of letting the external-provisioner
  # sidecar do it (`--enable-capacity`): the sidecar publishes capacity on a
  # poll interval. Between polls the value is stale, so a burst of
  # CreateVolume calls all see the same capacity reading and pile onto the
  # same node before the next poll catches up. By writing the objects
  # ourselves on every CreateVolume / DeleteVolume, the scheduler sees
  # fresh data on the very next decision and the burst race closes.
  #
  # Each (hostname × storage_class) pair gets one CSIStorageCapacity. We
  # baseline-from-disk on a slow timer (`reconcile`) and adjust by
  # in-flight pending reservations on every reserve / release.
  class CapacityManager
    include ServiceHelper

    # Headroom over kubelet's eviction threshold. Has to absorb fs
    # overhead (a 10 GiB sparse PV ends up ~11 GiB once written) and
    # any customer ephemeral storage; otherwise full PVs trip
    # DiskPressure and trap themselves on the tainted node.
    RESERVE_PERCENT = 25

    # Pending reservations expire if the volume never gets staged. This
    # bounds the damage from CreateVolumes that succeed but never have a
    # backing file created on the node (e.g. the PV is deleted before
    # NodeStageVolume runs).
    RESERVATION_TTL_SECONDS = 600

    # How often the background thread re-baselines capacity from disk.
    RECONCILE_INTERVAL_SECONDS = 30

    # The script emits raw building blocks rather than computing capacity
    # itself so callers can also see which backing files are already on
    # disk. We use that list to drop pending entries whose vol_id has
    # been staged (and is therefore now reflected in `uncommitted`).
    #
    # Output:
    #   line 1: "<df_total> <df_avail> <uncommitted>" (all bytes)
    #   line 2..N: one vol-id per backing file (sorted)
    def self.capacity_script
      @capacity_script ||= <<~SH.freeze
        set -e
        df_total=$(df --output=size -B1 #{V1::NodeService::VOLUME_BASE_PATH} | tail -n1)
        df_avail=$(df --output=avail -B1 #{V1::NodeService::VOLUME_BASE_PATH} | tail -n1)
        uncommitted=$(find #{V1::NodeService::VOLUME_BASE_PATH} -maxdepth 1 -name '*.img' -printf '%s %b\\n' | awk 'BEGIN{u=0} {u += $1 - $2*512} END{print int(u+0)}')
        echo "$df_total $df_avail $uncommitted"
        find #{V1::NodeService::VOLUME_BASE_PATH} -maxdepth 1 -name '*.img' -printf '%f\\n' | sed 's/\\.img$//' | sort
      SH
    end

    def self.parse_capacity_output(output)
      lines = output.lines.map(&:strip).reject(&:empty?)
      header = lines.first.to_s.split
      unless header.size == 3
        raise "Unexpected capacity output: #{output.inspect}"
      end
      df_total, df_avail, uncommitted = header.map { |s| Integer(s, 10) }
      {df_total:, df_avail:, uncommitted:, staged_ids: lines[1..]}
    end

    # The kube-apiserver normalizes resource.Quantity fields, so a
    # capacity we wrote as "3260544000" comes back as "3260544k". We
    # need bytes for comparison.
    QUANTITY_DECIMAL = {"k" => 10**3, "M" => 10**6, "G" => 10**9, "T" => 10**12, "P" => 10**15, "E" => 10**18}.freeze
    QUANTITY_BINARY = {"Ki" => 1024, "Mi" => 1024**2, "Gi" => 1024**3, "Ti" => 1024**4, "Pi" => 1024**5, "Ei" => 1024**6}.freeze

    def self.parse_quantity(value)
      s = value.to_s.strip
      return 0 if s.empty?
      return Integer(s, 10) if s.match?(/\A-?\d+\z/)
      if (m = s.match(/\A(-?\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|Pi|Ei)\z/))
        return (m[1].to_f * QUANTITY_BINARY.fetch(m[2])).to_i
      end
      if (m = s.match(/\A(-?\d+(?:\.\d+)?)(k|M|G|T|P|E)\z/))
        return (m[1].to_f * QUANTITY_DECIMAL.fetch(m[2])).to_i
      end
      raise ArgumentError, "Unrecognized Kubernetes quantity: #{value.inspect}"
    end

    def initialize(logger:, max_volume_size:)
      @logger = logger
      @max_volume_size = max_volume_size
      @pending = {}  # hostname => {vol_id => {size:, created_at:}}
      @known = {}    # hostname => {storage_class => {object_name:, base_capacity:, last_published:}}
      @mutex = Mutex.new
      @queue = Queue.new
      @shutdown = false
      @owner_ref = nil
    end

    def start
      @owner_ref = kubernetes_client.get_provisioner_deployment_owner_ref
      spawn_reconcile_thread
      @logger.info("[CapacityManager] Started capacity manager")
    end

    def shutdown!
      @shutdown = true
      @queue.close
      @thread&.join
    end

    def spawn_reconcile_thread
      @thread = Thread.new do
        until @shutdown
          begin
            reconcile
          rescue => e
            @logger.error("[CapacityManager] reconcile failed: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
          end
          @queue.pop(timeout: RECONCILE_INTERVAL_SECONDS)
        end
      end
    end

    # Atomically check + record a reservation. Returns true if accepted,
    # false if it would push the host over its base capacity. The check
    # closes the burst race that controller-managed CSIStorageCapacity
    # alone leaves open: when N PVCs schedule in parallel they all see
    # the same pre-burst capacity, and CreateVolume is the only point
    # where we can reject the late ones so external-provisioner forces
    # the scheduler to re-evaluate.
    def reserve(hostname:, vol_id:, size_bytes:)
      reserved = @mutex.synchronize do
        bucket = @known[hostname]
        # If we don't have a baseline yet (first reconcile hasn't run
        # for this host), trust the scheduler — the next reconcile will
        # publish accurate state.
        if bucket && !bucket.empty?
          base = bucket.values.first[:base_capacity]
          current_pending = (@pending[hostname] || {}).values.sum { |e| e[:size] }
          next false if current_pending + size_bytes > base
        end
        @pending[hostname] ||= {}
        @pending[hostname][vol_id] = {size: size_bytes, created_at: Time.now}
        true
      end
      publish_for_host(hostname) if reserved
      reserved
    end

    def release(vol_id:)
      hostname = @mutex.synchronize do
        host = @pending.find { |_, bucket| bucket.key?(vol_id) }&.first
        @pending[host].delete(vol_id) if host
        host
      end
      publish_for_host(hostname) if hostname
    end

    def reconcile
      client = kubernetes_client
      hostnames = client.list_csi_nodes_with_driver
      storage_classes = client.list_storage_classes_for_driver
      existing_objects = client.list_csi_storage_capacities

      existing_by_key = existing_objects.to_h do |obj|
        host = obj.dig("nodeTopology", "matchLabels", "kubernetes.io/hostname")
        sc = obj["storageClassName"]
        [[host, sc], obj]
      end

      expected_keys = []
      hostnames.each do |hostname|
        cap = fetch_node_capacity(client, hostname)
        next unless cap

        prune_pending(hostname, cap[:staged_ids])

        storage_classes.each do |sc|
          expected_keys << [hostname, sc]
          upsert_capacity(client, hostname, sc, cap, existing_by_key[[hostname, sc]])
        end
      end

      existing_by_key.each do |key, obj|
        next if expected_keys.include?(key)
        client.delete_csi_storage_capacity(name: obj.dig("metadata", "name"))
      end

      @mutex.synchronize do
        @known.delete_if { |host, _| !hostnames.include?(host) }
      end
    end

    def kubernetes_client
      @kubernetes_client ||= KubernetesClient.new(req_id: SecureRandom.uuid, logger: @logger, log_level: :debug)
    end

    private

    def prune_pending(hostname, staged_ids)
      now = Time.now
      @mutex.synchronize do
        bucket = @pending[hostname] ||= {}
        bucket.delete_if do |vol_id, entry|
          staged_ids.include?(vol_id) || (now - entry[:created_at]) > RESERVATION_TTL_SECONDS
        end
      end
    end

    def upsert_capacity(client, hostname, storage_class, cap, existing_obj)
      reserve_bytes = cap[:df_total] * RESERVE_PERCENT / 100
      base_capacity = [cap[:df_avail] - cap[:uncommitted] - reserve_bytes, 0].max

      pending_sum = @mutex.synchronize { (@pending[hostname] || {}).values.sum { |p| p[:size] } }
      published = [base_capacity - pending_sum, 0].max
      # The kube-scheduler's VolumeBinding plugin uses maximumVolumeSize
      # over capacity for filtering when both are set, so a published
      # capacity of 0 still admits PVCs unless we cap maximumVolumeSize
      # at the same value. Clamp to the per-PV global limit too so we
      # don't advertise volumes larger than DISK_LIMIT_GB.
      max_volume_size = [published, @max_volume_size].min

      if existing_obj
        object_name = existing_obj.dig("metadata", "name")
        current_capacity = self.class.parse_quantity(existing_obj["capacity"])
        current_max_volume_size = self.class.parse_quantity(existing_obj["maximumVolumeSize"])
        if current_capacity != published || current_max_volume_size != max_volume_size
          client.patch_csi_storage_capacity(
            name: object_name,
            capacity_bytes: published,
            max_volume_size:,
          )
        end
      else
        object_name = object_name_for(hostname, storage_class)
        client.create_csi_storage_capacity(
          name: object_name,
          hostname:,
          storage_class:,
          capacity_bytes: published,
          max_volume_size:,
          owner_ref: @owner_ref,
        )
      end

      @mutex.synchronize do
        @known[hostname] ||= {}
        @known[hostname][storage_class] = {
          object_name:,
          base_capacity:,
          last_published: published,
        }
      end
    end

    def publish_for_host(hostname)
      patches = @mutex.synchronize do
        bucket = @known[hostname] || {}
        pending_sum = (@pending[hostname] || {}).values.sum { |e| e[:size] }
        bucket.filter_map do |_sc, info|
          published = [info[:base_capacity] - pending_sum, 0].max
          next if info[:last_published] == published
          info[:last_published] = published
          {name: info[:object_name], capacity_bytes: published, max_volume_size: [published, @max_volume_size].min}
        end
      end

      return if patches.empty?

      client = kubernetes_client
      patches.each do |args|
        client.patch_csi_storage_capacity(**args)
      rescue => e
        @logger.error("[CapacityManager] patch failed for #{args[:name]}: #{e.class} - #{e.message}")
      end
    end

    def fetch_node_capacity(client, hostname)
      node_ip = client.get_node_ip(hostname)
      # LogLevel=ERROR suppresses ssh's "Permanently added <host> to the
      # list of known hosts" warning. Without it, that warning gets
      # merged with stdout by capture2e and breaks parse_capacity_output.
      cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-i", "/ssh/id_ed25519", "ubi@#{node_ip}", self.class.capacity_script]
      output, status = run_cmd(*cmd, req_id: "capacity-#{hostname}")
      unless status.success?
        @logger.error("[CapacityManager] capacity script on #{hostname} failed: #{output}")
        return nil
      end
      self.class.parse_capacity_output(output)
    rescue => e
      @logger.error("[CapacityManager] fetch_node_capacity failed for #{hostname}: #{e.class} - #{e.message}")
      nil
    end

    def object_name_for(hostname, storage_class)
      "csisc-#{hostname}-#{storage_class}"
    end
  end
end
