# frozen_string_literal: true

require_relative "../../common/lib/util"
require "json"

class IpReachabilityCheck
  def initialize(ips)
    @ips = ips.uniq
  end

  def run
    all_targets = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    targets = all_targets.select { |target| reachable?(nil, target) }
    fail "host cannot reach any of #{all_targets.join(", ")}" if targets.empty?

    # Failed addresses are checked a second time so that a lost burst of
    # pings doesn't count as a blocked address.
    check_concurrently(check_concurrently(@ips, targets), targets)
  end

  def check_concurrently(ips, targets)
    queue = Queue.new
    ips.each { |ip| queue << ip }
    queue.close

    failed = Queue.new
    Array.new([32, ips.size].min) {
      Thread.new do
        # join re-raises the exception, which is reported there.
        Thread.current.report_on_exception = false
        while (ip = queue.pop)
          failed << ip unless check(ip, targets)
        end
      end
    }.each(&:join)

    Array.new(failed.size) { failed.pop }.sort_by { |ip| ips.index(ip) }
  end

  def check(ip, targets)
    with_address(ip) do
      targets.all? { |target| reachable?(ip, target) }
    end
  end

  def reachable?(source, target)
    command = ["ping", "-n", "-q", "-c", "5", "-i", "0.2", "-W", "2"]
    command += ["-I", source] if source
    command << target
    r(*command, expect: [0, 1])[/(\d+) received/, 1].to_i > 0
  end

  def with_address(ip)
    return yield if configured_addresses.include?(ip)

    begin
      r("ip", "addr", "replace", "#{ip}/32", "dev", "lo")
      yield
    ensure
      # Exit status 2 means the address was never added.
      r("ip", "addr", "del", "#{ip}/32", "dev", "lo", expect: [0, 2])
    end
  end

  def configured_addresses
    @configured_addresses ||= JSON.parse(r("ip", "-j", "-4", "addr", "show")).flat_map do |link|
      next [] if link["ifname"] == "lo"
      link.fetch("addr_info", []).map { |info| info["local"] }
    end
  end
end
