# frozen_string_literal: true

require_relative "../model"

require "time"

class Strand < Sequel::Model
  # We need to unrestrict primary key so strand.add_child works in Prog::Base.
  unrestrict_primary_key

  Strand.plugin :defaults_setter, cache: true
  Strand.default_values[:stack] = proc { [{}] }

  LEASE_EXPIRATION = 120
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :children, key: :parent_id, class: self
  one_to_many :semaphores

  plugin ResourceMethods

  def subject
    return @subject if defined?(@subject) && @subject != :reload
    @subject = UBID.decode(ubid)
  end

  RespirateMetrics = Struct.new(:scheduled, :scan_picked_up, :worker_started, :lease_checked, :lease_acquired, :queue_size, :available_workers, :old_strand, :lease_expired) do
    def scan_delay
      scan_picked_up - scheduled
    end

    def queue_delay
      worker_started - scan_picked_up
    end

    def lease_delay
      lease_checked - worker_started
    end

    def total_delay
      lease_checked - scheduled
    end
  end

  # If the lease time is after this, we must be dealing with an
  # expired lease, since normal lease times are either in the future
  # or 1000 years in the past.
  EXPIRED_LEASE_TIME = Time.utc(2025)

  def respirate_metrics
    lease_expired = lease > EXPIRED_LEASE_TIME
    @respirate_metrics ||= RespirateMetrics.new(scheduled: lease_expired ? lease : schedule, lease_expired:)
  end

  def scan_picked_up!
    respirate_metrics.scan_picked_up = Time.now
  end

  def worker_started!
    respirate_metrics.worker_started = Time.now
  end

  def lease_checked!(affected)
    respirate_metrics.lease_checked = Time.now
    respirate_metrics.lease_acquired = true if affected
  end

  def old_strand!
    respirate_metrics.old_strand = true
  end

  # :nocov:
  ps_sch = if Config.development?
    Sequel.function(:least, 5, :try)
  # :nocov:
  else
    Sequel.function(:least, Sequel[2]**Sequel.function(:least, :try, 20), 600) * Sequel.function(:random)
  end

  TAKE_LEASE_PS = DB[:strand]
    .returning
    .where(
      Sequel[id: DB[:strand].select(:id).where(id: :$id).for_update.skip_locked, exitval: nil] &
        (Sequel[:lease] < Sequel::CURRENT_TIMESTAMP)
    )
    .prepare_sql_type(:update)
    .prepare(:first, :strand_take_lease_and_reload,
      lease: Sequel::CURRENT_TIMESTAMP + Sequel.cast("120 seconds", :interval),
      try: Sequel[:try] + 1,
      schedule: Sequel::CURRENT_TIMESTAMP + (ps_sch * Sequel.cast("1 second", :interval)))

  RELEASE_LEASE_PS = DB[<<SQL, :$id, :$lease_time].prepare(:update, :strand_release_lease)
UPDATE strand SET lease = now() - '1000 years'::interval WHERE id = ? AND lease = ?
SQL

  def take_lease_and_reload
    affected = TAKE_LEASE_PS.call(id:)
    lease_checked!(affected)
    return false unless affected
    lease_time = affected.fetch(:lease)

    # Also operate as reload query
    _refresh_set_values(affected)
    _clear_changed_columns(:refresh)
    @subject = :reload

    begin
      yield
    ensure
      if @deleted
        if exists?
          fail "BUG: strand with @deleted set still exists in the database"
        end
      else
        unless RELEASE_LEASE_PS.call(id:, lease_time:) == 1
          Clog.emit("lease violated data") { {lease_clear_debug_snapshot: this.for_update.all} }
          fail "BUG: lease violated"
        end
      end
    end
  end

  def self.prog_verify(prog)
    case prog.name
    when /\AProg::(.*)\z/
      $1
    else
      fail "BUG: prog must be in Prog module"
    end
  end

  def load(snap = nil)
    Object.const_get("::Prog::" + prog).new(self, snap)
  end

  def unsynchronized_run
    start_time = Time.now
    prog_label = "#{prog}.#{label}"
    top_frame = stack.first

    if label == top_frame["deadline_target"]
      Page.from_tag_parts("Deadline", id, prog, top_frame["deadline_target"])&.incr_resolve

      top_frame.delete("deadline_target")
      top_frame.delete("deadline_at")

      modified!(:stack)
    end

    effective_prog = prog
    stack.each do |frame|
      if (deadline_at = frame["deadline_at"])
        if Time.now > Time.parse(deadline_at.to_s)
          sbj = subject
          extra_data = case sbj
          when Vm
            {vm_host: sbj.vm_host&.ubid, data_center: sbj.vm_host&.data_center, boot_image: sbj.boot_image, location: sbj.location.display_name, arch: sbj.arch, vcpus: sbj.vcpus, ipv4: sbj.ephemeral_net4.to_s}
          when VmHost
            {data_center: sbj.data_center, location: sbj.location.display_name, arch: sbj.arch, ipv4: sbj.sshable.host, total_cores: sbj.total_cores, allocation_state: sbj.allocation_state, os_version: sbj.os_version, vm_count: sbj.vms_dataset.count}
          when GithubRunner
            {label: sbj.label, installation: sbj.installation.ubid, vm: sbj.vm&.ubid, vm_host: sbj.vm&.vm_host&.ubid, data_center: sbj.vm&.vm_host&.data_center}
          else
            {}
          end
          extra_data.compact!
          Prog::PageNexus.assemble("#{ubid} has an expired deadline! #{effective_prog}.#{label} did not reach #{frame["deadline_target"]} on time", ["Deadline", id, effective_prog, frame["deadline_target"]], ubid, extra_data:)
          modified!(:stack)
        end
      end

      if (link = frame["link"])
        effective_prog = link[0]
      end
    end

    unless top_frame["last_label_changed_at"]
      top_frame["last_label_changed_at"] = Time.now.to_s
      modified!(:stack)
    end

    DB.transaction do
      SemSnap.use(id) do |snap|
        prg = load(snap)
        prg.public_send(:before_run) if prg.respond_to?(:before_run)
        prg.public_send(label)
      end
    rescue Prog::Base::Nap => e
      save_changes

      scheduled = DB[<<SQL, e.seconds, id].get
UPDATE strand
SET try = 0, schedule = now() + (? * '1 second'::interval)
WHERE id = ?
RETURNING schedule
SQL
      # For convenience, reflect the updated record's schedule content
      # in the model object, but since it's fresh, remove it from the
      # changed columns so save_changes won't update it again.
      self.schedule = scheduled
      changed_columns.delete(:schedule)
      e
    rescue Prog::Base::Hop => hp
      last_changed_at = Time.parse(top_frame["last_label_changed_at"])
      Clog.emit("hopped") { {strand_hopped: {duration: Time.now - last_changed_at, from: prog_label, to: "#{hp.new_prog}.#{hp.new_label}"}} }
      top_frame["last_label_changed_at"] = Time.now.to_s
      modified!(:stack)

      update(**hp.strand_update_args, try: 0)

      hp
    rescue Prog::Base::Exit => ext
      last_changed_at = Time.parse(top_frame["last_label_changed_at"])
      Clog.emit("exited") { {strand_exited: {duration: Time.now - last_changed_at, from: prog_label}} }

      update(exitval: ext.exitval, retval: nil)
      if parent_id.nil?
        # No parent Strand to reap here, so self-reap.
        Semaphore.where(strand_id: id).destroy
        destroy
        @deleted = true
      end

      ext
    else
      fail "BUG: Prog #{prog}##{label} did not provide flow control"
    end
  ensure
    duration = Time.now - start_time
    Clog.emit("finished strand") { [self, {strand_finished: {duration:, prog_label:}}] } if duration > 1
  end

  def run(seconds = 0)
    fail "already deleted" if @deleted
    deadline = Time.now + seconds
    take_lease_and_reload do
      loop do
        ret = unsynchronized_run
        now = Time.now
        if now > deadline ||
            (ret.is_a?(Prog::Base::Nap) && ret.seconds != 0) ||
            ret.is_a?(Prog::Base::Exit)
          return ret
        end
      end
    end
  end
end

# Table: strand
# Columns:
#  id        | uuid                     | PRIMARY KEY
#  parent_id | uuid                     |
#  schedule  | timestamp with time zone | NOT NULL DEFAULT now()
#  lease     | timestamp with time zone | NOT NULL DEFAULT (now() - '1000 years'::interval)
#  prog      | text                     | NOT NULL
#  label     | text                     | NOT NULL
#  stack     | jsonb                    | NOT NULL DEFAULT '[{}]'::jsonb
#  exitval   | jsonb                    |
#  retval    | jsonb                    |
#  try       | integer                  | NOT NULL DEFAULT 0
# Indexes:
#  strand_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  strand_parent_id_fkey | (parent_id) REFERENCES strand(id)
# Referenced By:
#  semaphore | semaphore_strand_id_fkey | (strand_id) REFERENCES strand(id)
#  strand    | strand_parent_id_fkey    | (parent_id) REFERENCES strand(id)
