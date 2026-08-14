# frozen_string_literal: true

module MaintenanceWindow
  MAINTENANCE_DURATION_IN_HOURS = 2
  DAYS_OF_WEEK = %w[mon tue wed thu fri sat sun].freeze
  DAYS_OF_WEEK_BIT = DAYS_OF_WEEK.each_with_index.to_h { |d, i| [d, 1 << i] }.freeze

  module ClassMethods
    def maintenance_hour_options
      Array.new(24) do
        [it, "#{"%02d" % it}:00 - #{"%02d" % ((it + MAINTENANCE_DURATION_IN_HOURS) % 24)}:00 (UTC)"]
      end
    end

    def maintenance_window_days_mask(names)
      return 0 if names.nil? || names.empty?

      # Days of week are stored as a bitmask and presented to the user
      # as list of short strings stored in DAYS_OF_WEEK
      names.reduce(0) do |mask, name|
        mask | DAYS_OF_WEEK_BIT.fetch(name.to_s.downcase) do
          fail Validation::ValidationFailed.new({maintenance_window_days: "\"#{name}\" is not a valid day. Valid days: #{DAYS_OF_WEEK.join(", ")}"})
        end
      end
    end
  end

  module InstanceMethods
    def in_maintenance_window?
      return true if maintenance_window_start_at.nil?
      now = Time.now.utc
      offset = (now.hour - maintenance_window_start_at) % 24
      return false unless offset < MAINTENANCE_DURATION_IN_HOURS
      return true if maintenance_window_days_bitmask.zero?

      # Check the day the window opened at, in case window crosses the midnight
      bit = ((now - offset * 3600).wday + 6) % 7
      maintenance_window_days_bitmask[bit] == 1
    end

    def validate
      super
      validates_includes(0..23, :maintenance_window_start_at, allow_nil: true, message: "must be between 0 and 23")
      validates_includes(0..127, :maintenance_window_days_bitmask, allow_nil: true, message: "must be between 0 and 127")
    end

    # An empty list means the window applies every day (the bitmask is 0).
    def maintenance_window_day_names
      DAYS_OF_WEEK.each_with_index.filter_map { |d, i| d if maintenance_window_days_bitmask[i] == 1 }
    end

    # [day, checked] pairs for the maintenance window days.
    def maintenance_window_day_options_state
      DAYS_OF_WEEK.each_with_index.map { |day, i| [day, maintenance_window_days_bitmask[i] == 1] }
    end
  end
end
