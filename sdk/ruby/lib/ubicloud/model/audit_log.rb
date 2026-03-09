# frozen_string_literal: true

module Ubicloud
  # Ubicloud::AuditLog provides access to the project audit log via the
  # Ubicloud API.  Unlike other models, audit log entries are read-only
  # and are accessed only via the +list+ class method.
  class AuditLog
    # Return an array of audit log entry hashes for the project. If
    # the +subject+ keyword argument is provided, only entries whose
    # subject matches the given UBID are returned. If the +object+
    # keyword argument is provided, only entries affecting the object
    # with the given UBID are returned.
    def self.list(adapter, subject: nil, object: nil)
      path = "audit-log"
      query_parts = []
      query_parts << "subject=#{subject}" if subject
      query_parts << "object=#{object}" if object
      path = "#{path}?#{query_parts.join("&")}" unless query_parts.empty?
      adapter.get(path)[:items]
    end
  end
end
