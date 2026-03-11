# frozen_string_literal: true

module Ubicloud
  # Ubicloud::AuditLog provides access to the project audit log via the
  # Ubicloud API.  Unlike other models, audit log entries are read-only
  # and are accessed only via the +search+ class method.
  class AuditLog < Model
    # Represents one page of audit log results. To get additional pages,
    # next_page can be called.
    class Page < Array
      attr_writer :adapter

      # A hash of keyword arguments used to retrieve the next page.
      attr_accessor :next_page_args

      # If there are more records for the search beyond those in the
      # current page, return another Page with additional records.
      # Otherwise, return nil to signal this is the last page.
      def next_page
        if @adapter && @next_page_args
          AuditLog.search(@adapter, **@next_page_args)
        end
      end
    end

    set_prefix "a1"

    set_fragment "audit-log"

    set_columns :at, :action, :subject_id, :subject_name, :object_ids

    class << self
      # Remove inherited methods that don't make sense for AuditLog.
      undef_method :[]
      undef_method :create
      undef_method :list

      # Return a Page of matching audit log entry hashes for the project.
      # Without keyword arguments, returns the most recent audit log entries.
      def search(adapter, action: nil, subject: nil, object: nil, end: nil, limit: nil, pagination_key: nil)
        _search(adapter, action:, subject:, object:, end:, limit:, pagination_key:)
      end

      private

      # Internals of search, used to DRY up handling of the keyword arguments
      # without using Binding#local_variable_get.
      def _search(adapter, **opts)
        query_parts = opts.filter_map do |key, value|
          "#{key}=#{value}" if value
        end

        path = "audit-log?#{query_parts.join("&")}"
        result = adapter.get(path)

        page = Page.new.replace(result[:items]).map! { new(adapter, it) }

        if result[:pagination_key]
          opts[:pagination_key] = result[:pagination_key]
          page.adapter = adapter
          page.next_page_args = opts
        end

        page
      end
    end

    def initialize(adapter, values)
      @adapter = adapter
      @values = values
    end

    # Do not send a query at runtime to retrieve more information, as audit
    # log entries are complete.
    def info
      nil
    end

    # Remove inherited methods that don't make sense for AuditLog.
    undef_method :location
    undef_method :name
    undef_method :load_object_info_from_id
    undef_method :rename_to
    undef_method :destroy
    undef_method :id
    undef_method :check_exists
  end
end
