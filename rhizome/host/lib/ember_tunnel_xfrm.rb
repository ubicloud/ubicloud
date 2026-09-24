# frozen_string_literal: true

require_relative "../../common/lib/util"
require "fileutils"
require "json"

# One end of the IPsec mesh between a location's gateway replicas and its ember
# hosts, made to match a spec the control plane sends: ESP in tunnel mode,
# set up with ip xfrm, the same as a private subnet's tunnels.
#
# The spec is the whole of this end's tunnels, so applying it is idempotent:
# what is missing is added and what this end installed but is no longer in
# the spec is removed. Anything else in the namespace -- a gateway VM's
# private subnet tunnels live in the same one -- is left alone, because only
# what is recorded in the state file as installed here is ever deleted.
class EmberTunnelXfrm
  STATE_DIR = "/var/lib/ember-tunnel"
  AEAD = "rfc4106(gcm(aes)) %s 128"

  def initialize(spec)
    @spec = spec
    @netns = spec["netns"]
    @self = spec.fetch("self")
    @peers = spec.fetch("peers")
  end

  def state_file = File.join(STATE_DIR, "#{@netns || "root"}.json")

  # Returns whether the spec was applied. One older than the last applied is
  # not: of two pushes racing each other, the later view of the database wins.
  def apply
    FileUtils.mkdir_p(STATE_DIR)
    File.open(state_file + ".lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      state = read_state
      return false if state["serial"] && @spec.fetch("serial") < state["serial"]

      # New states first and stale ones last, so a policy never points at a
      # state that is not there: switching the outbound key between the two
      # otherwise drops a packet.
      present = kernel_states
      add_states(present)
      update_policies
      delete_stale_policies(state)
      delete_stale_states(state, present)
      write_state
      guard_slots unless @netns
      true
    end
  end

  def guard_slots
    r("nft", "-f", "-", stdin: <<~NFT)
      table inet ember_host
      delete table inet ember_host
      table inet ember_host {
        chain forward { type filter hook forward priority filter; policy accept;
          oifname "emo*" meta ipsec missing counter drop
        }
      }
    NFT
  end

  # [src, dst, spi, reqid, key] for every SA this end should have: its own
  # outbound one to each peer, and an inbound one for each key a peer may
  # send with -- two while that peer is rekeying.
  def desired_states
    out = @self.fetch("outbound")
    @peers.flat_map do |peer|
      [[@self["outer"], peer["outer"], out["spi"], out["reqid"], out["key"]]] +
        peer.fetch("keys").map { |key| [peer["outer"], @self["outer"], key["spi"], key["reqid"], key["key"]] }
    end
  end

  # [src, dst, dir, tmpl_src, tmpl_dst, reqid]. Traffic in both directions is
  # forwarded rather than delivered here -- to the gateway VM on one end, to a
  # slot on the other -- so the receiving side needs a fwd policy, and an
  # unprotected packet that claims to come from a peer is dropped by it.
  def desired_policies
    out = @self.fetch("outbound")
    @peers.flat_map do |peer|
      [[@self["inner"], peer["inner"], "out", @self["outer"], peer["outer"], out["reqid"]],
        [peer["inner"], @self["inner"], "fwd", peer["outer"], @self["outer"], 0]]
    end
  end

  private

  def read_state
    File.exist?(state_file) ? JSON.parse(File.read(state_file)) : {}
  rescue JSON::ParserError
    {}
  end

  def write_state
    state = {
      "serial" => @spec.fetch("serial"),
      "states" => desired_states.map { |sa| sa.first(3) },
      "policies" => desired_policies.map { |policy| policy.first(3) },
    }
    safe_write_to_file(state_file) { |f| f.write(JSON.generate(state)) }
    File.chmod(0o600, state_file)
  end

  def ip(*args, stdin: nil)
    ns = @netns ? ["-n", @netns] : []
    r("ip", *ns, *args, stdin: stdin)
  end

  # [src, dst, spi] of every ESP state in the namespace. The kernel is asked
  # rather than trusted to match the state file, because a reboot empties it.
  def kernel_states
    ip("xfrm", "state").scan(/^src (\S+) dst (\S+)\s+proto esp spi (0x[0-9a-f]+)/)
  end

  # Through -batch, so the keys travel on stdin rather than in a command line
  # anyone on the host could read.
  def add_states(present)
    additions = desired_states.reject { |sa| present.include?(sa.first(3)) }.map do |src, dst, spi, reqid, key|
      "xfrm state add src #{src} dst #{dst} proto esp spi #{spi} reqid #{reqid} mode tunnel " \
        "aead #{format(AEAD, key)} flag esn replay-window 4096\n"
    end
    ip("-batch", "-", stdin: additions.join) unless additions.empty?
  end

  # update adds a policy that is missing and replaces one that is not.
  def update_policies
    desired_policies.each do |src, dst, dir, tmpl_src, tmpl_dst, reqid|
      ip("xfrm", "policy", "update", "src", src, "dst", dst, "dir", dir,
        "tmpl", "src", tmpl_src, "dst", tmpl_dst, "proto", "esp", "reqid", reqid.to_s, "mode", "tunnel")
    end
  end

  def delete_stale_policies(state)
    wanted = desired_policies.map { |policy| policy.first(3) }
    (state["policies"] || []).each do |src, dst, dir|
      next if wanted.include?([src, dst, dir])
      begin
        ip("xfrm", "policy", "delete", "src", src, "dst", dst, "dir", dir)
      rescue CommandFail
        # Already gone, with the namespace it was in.
        nil
      end
    end
  end

  def delete_stale_states(state, present)
    wanted = desired_states.map { |sa| sa.first(3) }
    (state["states"] || []).each do |src, dst, spi|
      next if wanted.include?([src, dst, spi]) || !present.include?([src, dst, spi])
      ip("xfrm", "state", "delete", "src", src, "dst", dst, "proto", "esp", "spi", spi)
    end
  end
end
