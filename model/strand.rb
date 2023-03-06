# frozen_string_literal: true

require_relative "../model"

class Strand < Sequel::Model
  LEASE_EXPIRATION = 120

  def lease
    self.class.lease(id) do
      yield self
    end
  end

  def self.lease(id)
    affected = DB[<<SQL, id].first
UPDATE strand
SET lease = now() + '120 seconds'
WHERE id = ? AND (lease IS NULL OR lease < now())
RETURNING lease
SQL
    return false unless affected
    lease = affected.fetch(:lease)

    begin
      prog = yield
      true
    ensure
      num_updated = DB[<<SQL, id, lease].update
UPDATE strand
SET lease = NULL
WHERE id = ? AND lease = ?
SQL
      # Avoid leasing integrity check error if the record disappears
      # entirely.
      fail "BUG: lease violated" unless num_updated == 1 || prog&.deleted?
    end
  end

  def load
    Object.const_get("::Prog::" + prog).new(self)
  end

  def unsynchronized_run
    prog = load
    puts "running " + prog.class.to_s
    DB.transaction do
      prog.public_send(label)
    rescue Prog::Base::Hop => e
      puts e.to_s
    end
    puts "ran " + prog.class.to_s

    prog
  end

  def run
    lease do
      next unsynchronized_run
    end
  end
end
