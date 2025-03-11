# frozen_string_literal: true

require_relative "../model"

require "time"

class Strand < Sequel::Model
  Strand.plugin :defaults_setter, cache: true
  Strand.default_values[:stack] = proc { [{}] }

  LEASE_EXPIRATION = 120
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :children, key: :parent_id, class: self
  one_to_many :semaphores

  include ResourceMethods

  def subject
    UBID.decode(ubid)
  end

  def take_lease_and_reload
    affected = DB[<<SQL, id].first
UPDATE strand
SET lease = now() + '120 seconds', try = try + 1, schedule = #{SCHEDULE}
WHERE id = ? AND (lease IS NULL OR lease < now()) AND exitval IS NULL
RETURNING lease
SQL
    return false unless affected
    lease_time = affected.fetch(:lease)
    verbose_logging = rand(1000) == 0

    Clog.emit("obtained lease") { {lease_acquired: {time: lease_time, delay: Time.now - schedule}} } if verbose_logging
    reload

    begin
      yield
    ensure
      if @deleted
        unless DB["SELECT FROM strand WHERE id = ?", id].empty?
          fail "BUG: strand with @deleted set still exists in the database"
        end
      else
        DB.transaction do
          lease_clear_debug_snapshot = this.for_update.all
          num_updated = DB[<<SQL, id, lease_time].update
UPDATE strand
SET lease = NULL
WHERE id = ? AND lease = ?
SQL
          Clog.emit("lease cleared") { {lease_cleared: {num_updated: num_updated}} } if verbose_logging
          unless num_updated == 1
            Clog.emit("lease violated data") do
              {lease_clear_debug_snapshot: lease_clear_debug_snapshot}
            end
            fail "BUG: lease violated"
          end
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

  # :nocov:
  SCHEDULE = Config.development? ? "(now() + least(5, try) * '1 second'::interval)" : "(now() + least(2 ^ least(try, 20), 600) * random() * '1 second'::interval)"
  # :nocov:

  def load(snap = nil)
    Object.const_get("::Prog::" + prog).new(self, snap)
  end

  def unsynchronized_run
    start_time = Time.now
    prog_label = "#{prog}.#{label}"

    if label == stack.first["deadline_target"]
      if (pg = Page.from_tag_parts("Deadline", id, prog, stack.first["deadline_target"]))
        pg.incr_resolve
      end

      stack.first.delete("deadline_target")
      stack.first.delete("deadline_at")

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

    unless stack.first["last_label_changed_at"]
      stack.first["last_label_changed_at"] = Time.now.to_s
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
      last_changed_at = Time.parse(stack.first["last_label_changed_at"])
      Clog.emit("hopped") { {strand_hopped: {duration: Time.now - last_changed_at, from: prog_label, to: "#{hp.new_prog}.#{hp.new_label}"}} }
      stack.first["last_label_changed_at"] = Time.now.to_s
      modified!(:stack)

      update(**hp.strand_update_args.merge(try: 0))

      hp
    rescue Prog::Base::Exit => ext
      last_changed_at = Time.parse(stack.first["last_label_changed_at"])
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

# We need to unrestrict primary key so strand.add_child works in Prog::Base.
Strand.unrestrict_primary_key

# Table: strand
# Columns:
#  id        | uuid                     | PRIMARY KEY
#  parent_id | uuid                     |
#  schedule  | timestamp with time zone | NOT NULL DEFAULT now()
#  lease     | timestamp with time zone |
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
