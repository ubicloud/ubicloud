# frozen_string_literal: true

require_relative "../model"

require "time"

class Strand < Sequel::Model
  Strand.plugin :defaults_setter, cache: true
  Strand.default_values[:stack] = proc { [{}] }

  LEASE_EXPIRATION = 120
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :children, key: :parent_id, class: self

  NAVIGATE = %w[vm vm_host sshable].freeze

  include ResourceMethods

  NAVIGATE.each do
    one_to_one _1.intern, key: :id
  end

  def take_lease_and_reload
    affected = DB[<<SQL, id].first
UPDATE strand
SET lease = now() + '120 seconds', try = try + 1, schedule = #{SCHEDULE}
WHERE id = ? AND (lease IS NULL OR lease < now())
RETURNING lease, exitval IS NOT NULL AS exited
SQL
    return false unless affected
    lease_time = affected.fetch(:lease)
    exited = affected.fetch(:exited)

    Clog.emit("obtained lease") { {lease_acquired: {time: lease_time, exited: exited}} }
    reload

    begin
      if exited
        # Clear any semaphores that get added to a exited Strand prog,
        # since incr is entitled to be run at *any time* (including
        # after exitval is set) and any such incements will prevent
        # deletion of a Strand via foreign_key
        Semaphore.where(strand_id: id).destroy
        return
      end

      yield
    ensure
      if @deleted
        unless DB["SELECT FROM strand WHERE id = ?", id].empty?
          fail "BUG: strand with @deleted set still exists in the database"
        end
      else
        num_updated = DB[<<SQL, id, lease_time].update
UPDATE strand
SET lease = NULL
WHERE id = ? AND lease = ?
SQL
        Clog.emit("lease cleared") { {lease_cleared: {num_updated: num_updated}} }
        unless num_updated == 1
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

  # :nocov:
  SCHEDULE = Config.development? ? "(now() + least(5, try) * '1 second'::interval)" : "(now() + least(2 ^ least(try, 20), 600) * random() * '1 second'::interval)"
  # :nocov:

  def load(snap = nil)
    Object.const_get("::Prog::" + prog).new(self, snap)
  end

  def unsynchronized_run
    start_time = Time.now
    prog_label = "#{prog}.#{label}"
    Clog.emit("starting strand") { {strand: values, time: start_time, prog_label: prog_label} }

    if label == stack.first["deadline_target"].to_s
      if (pg = Page.from_tag_parts(id, prog, stack.first["deadline_target"]))
        pg.incr_resolve
      end

      stack.first.delete("deadline_target")
      stack.first.delete("deadline_at")

      modified!(:stack)
    end

    stack.each do |frame|
      next unless (deadline_at = frame["deadline_at"])

      if Time.now > Time.parse(deadline_at.to_s)
        Prog::PageNexus.assemble("#{ubid} has an expired deadline! #{prog} did not reach #{frame["deadline_target"]} on time", id, prog, frame["deadline_target"])

        modified!(:stack)
      end
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
      update(**hp.strand_update_args)

      hp
    rescue Prog::Base::Exit => ext
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
    finish_time = Time.now
    Clog.emit("finished strand") { {strand: values, time: finish_time, duration: finish_time - start_time, prog_label: prog_label} }
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
