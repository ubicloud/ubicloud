# frozen_string_literal: true

require_relative "../../common/lib/util"

# Bounds the size of the rsyslog-written files under /var/log.
#
# These files are a duplicate of the systemd journal: rsyslog reads the journal
# and writes /var/log/syslog, /var/log/auth.log and friends. Nothing in the
# product consumes them -- OtelLogConfig ships postgres and pgbouncer logs to
# customer destinations from the journald receiver, not from /var/log -- so they
# exist purely for on-box debugging and can be rotated aggressively.
#
# The stock Ubuntu config (/etc/logrotate.d/rsyslog, an rsyslog conffile) is
# `weekly` with `rotate 4` and no size ceiling, so a single generation
# accumulates an entire week. On a busy server pgbouncer alone logs a line per
# client connect and disconnect, which is enough to reach multiple GB in one
# generation and fill the root filesystem. disk-full-check does not help here:
# it watches the /dat data disk, not the root filesystem.
#
# Two pieces are needed, and the timer is not optional:
#
#   1. MAXSIZE caps a single generation, so growth is bounded by volume rather
#      than by the calendar.
#   2. logrotate.timer runs daily out of the box, and `maxsize` is only
#      evaluated when logrotate actually runs -- a daily timer cannot enforce a
#      sub-daily cap. The drop-in moves it to hourly. This is safe for every
#      other logrotate config on the host: time-based configs still honor their
#      own daily/weekly interval regardless of how often logrotate is invoked,
#      so only maxsize configs rotate more frequently.
#
# We overwrite the rsyslog conffile in place rather than shipping our own file.
# logrotate aborts with "duplicate log entry" if two configs cover the same
# path, so a drop-in alongside the stock file is not an option. Package
# upgrades can drift the file, but unattended-upgrades runs --force-confold so
# the local version survives, and re-running this installer repairs drift.
class SyslogRotateConfig
  RSYSLOG_LOGROTATE_PATH = "/etc/logrotate.d/rsyslog"
  TIMER_OVERRIDE_DIR = "/etc/systemd/system/logrotate.timer.d"
  TIMER_OVERRIDE_PATH = File.join(TIMER_OVERRIDE_DIR, "10-ubicloud-hourly.conf")

  # Cap for a single generation. Two generations are uncompressed at any moment
  # -- the live file and, under delaycompress, the one behind it -- so this term
  # dominates the disk budget. Aged generations compress roughly 35x and are
  # nearly free by comparison.
  MAXSIZE = "500M"

  # Retention is bounded by count, not time: with maxsize doing the rotating, a
  # noisy server keeps fewer days than a quiet one. That is the intended
  # tradeoff -- these files are a journal duplicate, and bounding disk matters
  # more than a fixed retention window.
  #
  # Both constants are sized against a ~2 GB budget for the whole set. The
  # busiest server we have measured logs 31 MiB/h -- pgbouncer logs a line per
  # client connect and disconnect, which is what drives the busy case -- and at
  # these values keeps about a month of history for ~1.6 GB. The headroom is
  # deliberate: at 25x compression rather than the ~43x we actually see, the set
  # is still under budget. A quiet server never reaches maxsize, falls through
  # to `daily`, and keeps 45 days.
  ROTATE = 45

  # Paths from the stock Ubuntu rsyslog logrotate config. Kept verbatim so the
  # non-syslog files (notably auth.log, which also grows large) stay covered.
  LOG_PATHS = [
    "/var/log/syslog",
    "/var/log/mail.info",
    "/var/log/mail.warn",
    "/var/log/mail.err",
    "/var/log/mail.log",
    "/var/log/daemon.log",
    "/var/log/kern.log",
    "/var/log/auth.log",
    "/var/log/user.log",
    "/var/log/lpr.log",
    "/var/log/cron.log",
    "/var/log/debug",
    "/var/log/messages",
  ].freeze

  def logrotate_content
    <<~LOGROTATE
      # Managed by Ubicloud. Local edits are overwritten by configure-logs.
      #{LOG_PATHS.join("\n")}
      {
          rotate #{ROTATE}
          daily
          maxsize #{MAXSIZE}
          missingok
          notifempty
          compress
          delaycompress
          sharedscripts
          postrotate
              /usr/lib/rsyslog/rsyslog-rotate
          endscript
      }
    LOGROTATE
  end

  def timer_override_content
    <<~TIMER
      # Managed by Ubicloud. Local edits are overwritten by configure-logs.
      # maxsize in #{RSYSLOG_LOGROTATE_PATH} is only evaluated when logrotate
      # runs; the stock timer is daily, which is too coarse to enforce it.
      [Timer]
      OnCalendar=
      OnCalendar=hourly
      RandomizedDelaySec=5m
    TIMER
  end

  def setup
    # logrotate skips configs that are group- or world-writable, so the mode is
    # load-bearing rather than cosmetic. perm applies it before the rename, so
    # the file is never published at a mode logrotate would reject.
    safe_write_to_file(RSYSLOG_LOGROTATE_PATH, logrotate_content, perm: 0o644)

    r "mkdir", "-p", TIMER_OVERRIDE_DIR
    safe_write_to_file(TIMER_OVERRIDE_PATH, timer_override_content, perm: 0o644)

    r "systemctl", "daemon-reload"
    r "systemctl", "restart", "logrotate.timer"
  end
end
