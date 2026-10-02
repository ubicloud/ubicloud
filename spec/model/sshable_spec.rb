# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Sshable do
  # Avoid using excessive entropy by using one generated key for all
  # tests.
  key = SshKey.generate.keypair.freeze

  subject(:sa) {
    described_class.new(
      id: described_class.generate_uuid,
      host: "test.localhost",
      unix_user: "testuser",
      raw_private_key_1: key,
    )
  }

  def ssh_session(**)
    socket = instance_double(Socket, setsockopt: nil)
    instance_double(Net::SSH::Connection::Session,
      transport: instance_double(Net::SSH::Transport::Session, socket:), **)
  end

  it "can encrypt and decrypt a field" do
    sa.save_changes

    expect(sa.values[:raw_private_key_1] =~ /\AA[AgQ]..A/).not_to be_nil
    expect(sa.raw_private_key_1).to eq(key)
  end

  describe "#maybe_ssh_session_lock_name" do
    it "does not yield if SSH_SESSION_LOCK_NAME is not defined" do
      expect(sa.maybe_ssh_session_lock_name).to be_nil
    end

    if Config.unfrozen_test?
      it "yields if SSH_SESSION_LOCK_NAME is defined" do
        stub_const("SSH_SESSION_LOCK_NAME", "testlockname")
        expect(sa.maybe_ssh_session_lock_name).to eq("testlockname")
      end
    end
  end

  describe "session locking" do
    lock_script = <<LOCK
exec 999>/dev/shm/session-lock-testlockname || exit 92
flock -xn 999 || { echo "Another session active: " testlockname; exit 124; }
sleep infinity </dev/null >/dev/null 2>&1 &
disown
LOCK

    if File.directory?("/dev/shm")
      it "interlocks" do
        portable_pkill = lambda { system("fuser -k /dev/shm/session-lock-testlockname >/dev/null 2>&1") }
        portable_pkill.call
        q_lock_script = NetSsh.command(":lock_script", lock_script:)
        expect([`bash -c #{q_lock_script}`, $?.exitstatus]).to eq(["", 0])
        expect([`bash -c #{q_lock_script}`, $?.exitstatus]).to eq(["Another session active:  testlockname\n", 124])
        expect(portable_pkill.call).to be true
      end
    end

    describe "exit code handling" do
      before do
        expect(sa).to receive(:maybe_ssh_session_lock_name).and_return("testlockname")
        sa.invalidate_cache_entry
        expect(Net::SSH).to receive(:start) do
          ssh_session(close: nil)
        end
      end

      it "runs the session lock script if SSH_SESSION_LOCK_NAME is set" do
        expect(sa).to receive(:_cmd).with(lock_script, log: false)
        sa.connect
      end

      it "swallows a failure to obtain a file descriptor with an obscure exit code" do
        expect(sa).to receive(:_cmd).with(lock_script, log: false).and_raise(Sshable::SshError.new(lock_script, "", "", 92, nil))
        sa.connect
      end

      it "swallows lock conflicts when an obscure exit code is raised" do
        expect(sa).to receive(:_cmd).with(lock_script, log: false).and_raise(Sshable::SshError.new(lock_script, "", "", 124, nil))
        sa.connect
      end

      it "swallows unrecognized errors" do
        expect(sa).to receive(:_cmd).with(lock_script, log: false).and_raise(Sshable::SshError.new(lock_script, "", "", 1, nil))
        sa.connect
      end
    end
  end

  describe "caching" do
    # The cache is thread local, so re-set the thread state by boxing
    # each test in a new thread.
    around do |ex|
      Thread.new {
        ex.run
      }.join
    end

    it "can cache SSH connections" do
      expect(Net::SSH).to receive(:start) do
        ssh_session(close: nil, closed?: false, process: true)
      end

      expect(Thread.current[:clover_ssh_cache]).to be_nil
      first_time = sa.connect
      expect(Thread.current[:clover_ssh_cache].size).to eq(1)
      second_time = sa.connect
      expect(first_time).to equal(second_time)

      expect(described_class.reset_cache).to eq []
      expect(Thread.current[:clover_ssh_cache]).to be_empty
    end

    it "reconnects when the cached session was closed underneath it" do
      closed_sess = ssh_session(closed?: true)
      fresh_sess = ssh_session(closed?: false, process: true)
      expect(Net::SSH).to receive(:start).and_return(closed_sess, fresh_sess)

      expect(sa.connect).to equal(closed_sess)
      expect(sa.connect).to equal(fresh_sess)
      expect(sa.connect).to equal(fresh_sess)
      expect(Thread.current[:clover_ssh_cache]).to eq({["test.localhost", "testuser"] => fresh_sess})
    end

    it "turns Nagle's algorithm off on a new session" do
      sess = ssh_session(closed?: false)
      expect(sess.transport.socket).to receive(:setsockopt).with(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      expect(Net::SSH).to receive(:start).and_return(sess)
      sa.connect
    end

    it "reconnects when the server dropped the cached session while it sat idle" do
      dropped = ssh_session(closed?: false)
      fresh = ssh_session(closed?: false, process: true)
      expect(Net::SSH).to receive(:start).and_return(dropped, fresh)
      expect(dropped).to receive(:process).with(0).and_raise(Net::SSH::Disconnect, "connection closed by remote host")

      expect(sa.connect).to equal(dropped)
      expect(sa.connect).to equal(fresh)
    end

    it "reconnects when handling what was waiting closed the cached session" do
      dropped = ssh_session(process: true)
      expect(dropped).to receive(:closed?).and_return(false, true)
      fresh = ssh_session(closed?: false)
      expect(Net::SSH).to receive(:start).and_return(dropped, fresh)

      expect(sa.connect).to equal(dropped)
      expect(sa.connect).to equal(fresh)
    end

    it "does not crash if a cache has never been made" do
      expect {
        sa.invalidate_cache_entry
      }.not_to raise_error
    end

    it "can invalidate a single cache entry" do
      sess = ssh_session(close: nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect
      expect {
        sa.invalidate_cache_entry
      }.to change { Thread.current[:clover_ssh_cache] }.from({["test.localhost", "testuser"] => sess}).to({})
    end

    it "can reset caches when has cached connection" do
      sess = ssh_session(close: nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect
      expect {
        described_class.reset_cache
      }.to change { Thread.current[:clover_ssh_cache] }.from({["test.localhost", "testuser"] => sess}).to({})
    end

    it "can reset caches when has no cached connection" do
      expect(described_class.reset_cache).to eq([])
    end

    it "can reset caches even if session fails while closing" do
      sess = Net::SSH::Connection::Session.allocate
      allow(sess).to receive(:transport).and_return(ssh_session.transport)
      expect(sess).to receive(:close).and_raise Sshable::SshError.new("bogus", "", "", nil, nil)
      expect(Net::SSH).to receive(:start).and_return sess
      sa.connect

      expect(described_class.reset_cache.first).to be_a Sshable::SshError
      expect(Thread.current[:clover_ssh_cache]).to eq({})
    end
  end

  describe "#start_fresh_session" do
    def host_key
      pub = SshKey.generate.public_key
      [pub, Net::SSH::Buffer.new(pub.split(" ")[1].unpack1("m")).read_key]
    end

    def expect_ssh_start(server_key, session, verifier_class: Net::SSH::Verifiers::AcceptNew)
      expect(Net::SSH).to receive(:start).with("test.localhost", "testuser", hash_including(known_hosts: Sshable::KnownHosts)) do |*, **opts, &block|
        verifier = opts[:verify_host_key]
        verifier = Net::SSH::Verifiers::AcceptNew.new if verifier == :accept_new
        expect(verifier).to be_a(verifier_class)

        transport = instance_double(Net::SSH::Transport::Session, host_keys: opts[:known_hosts].search_for("test.localhost", opts))
        args = {key: server_key, key_blob: server_key.to_blob, fingerprint: "SHA256:test", session: transport}
        expect(verifier.verify(args)).to be true
        expect(verifier.verify_signature { :verified }).to eq :verified

        block ? block.call(session) : session
      end
    end

    before { sa.save_changes }

    it "does not record host keys for runner sshables" do
      sa.update(unix_user: "runneradmin")
      session = ssh_session
      expect(Net::SSH).to receive(:start).with("test.localhost", "runneradmin", any_args) do |*, **opts, &block|
        expect(opts.except(:key_data)).to eq described_class::COMMON_SSH_ARGS.except(:key_data)
        expect(opts[:key_data].map { Net::SSH::KeyFactory.load_data_private_key(it).public_key.to_blob })
          .to eq(sa.keys.map { Net::SSH::KeyFactory.load_data_private_key(it.private_key).public_key.to_blob })
        session
      end
      expect(Clog).not_to receive(:emit)

      expect(sa.start_fresh_session).to equal(session)
      expect(sa.reload.host_keys).to be_nil
    end

    it "records the host key when the sshable has no host keys" do
      pub, server_key = host_key
      session = ssh_session
      expect_ssh_start(server_key, session)
      expect(Clog).to receive(:emit).with("sshable host keys added", {sshable_host_keys_added: {sshable: sa.ubid, keys: [pub]}}).and_call_original

      expect(sa.start_fresh_session).to equal(session)
      expect(sa.host_keys).to eq [pub]
      expect(sa.reload.host_keys).to eq [pub]
    end

    it "records the host key before yielding when called with a block" do
      pub, server_key = host_key
      session = ssh_session
      expect_ssh_start(server_key, session)

      result = sa.start_fresh_session do |sess|
        expect(sess).to equal(session)
        expect(sa.reload.host_keys).to eq [pub]
        :block_result
      end
      expect(result).to eq :block_result
    end

    it "does not record host keys when the host offers a known host key" do
      pub, server_key = host_key
      other_pub, = host_key
      sa.update(host_keys: [other_pub, pub])
      session = ssh_session
      expect_ssh_start(server_key, session, verifier_class: Sshable::Verifier)
      expect(Clog).not_to receive(:emit)

      expect(sa.start_fresh_session).to equal(session)
      expect(sa.reload.host_keys).to eq [other_pub, pub]
    end

    it "logs and allows the connection when the host offers an unknown host key" do
      pub, = host_key
      _, server_key = host_key
      sa.update(host_keys: [pub])
      session = ssh_session
      expect_ssh_start(server_key, session, verifier_class: Sshable::Verifier)
      expect(Clog).to receive(:emit).with("sshable host key mismatch", {sshable_host_key_mismatch: {ubid: sa.ubid}}).and_call_original

      result = sa.start_fresh_session do |sess|
        expect(sess).to equal(session)
        :block_result
      end
      expect(result).to eq :block_result
      expect(sa.reload.host_keys).to eq [pub]
    end

    it "does not overwrite host keys concurrently recorded by another process" do
      pub, = host_key
      expect(Net::SSH).to receive(:start) do |*, **opts|
        sa.this.update(host_keys: Sequel.pg_array([pub], :text))
        opts[:known_hosts].search_for("test.localhost").add_host_key(host_key[1])
        ssh_session
      end
      expect(Clog).not_to receive(:emit)

      sa.start_fresh_session
      expect(sa.host_keys).to eq [pub]
    end
  end

  describe "#add_host_keys" do
    before { sa.save_changes }

    it "appends the keys and logs when the host keys have not changed concurrently" do
      sa.update(host_keys: ["ssh-ed25519 a"])
      expect(Clog).to receive(:emit).with("sshable host keys added", {sshable_host_keys_added: {sshable: sa.ubid, keys: ["ssh-ed25519 b"]}}).and_call_original

      sa.add_host_keys(["ssh-ed25519 b"])
      expect(sa.host_keys).to eq ["ssh-ed25519 a", "ssh-ed25519 b"]
      expect(sa.reload.host_keys).to eq ["ssh-ed25519 a", "ssh-ed25519 b"]
    end

    it "does not update or log when the host keys have changed concurrently" do
      sa.update(host_keys: ["ssh-ed25519 a"])
      sa.this.update(host_keys: Sequel.pg_array(["ssh-ed25519 c"], :text))
      expect(Clog).not_to receive(:emit)

      sa.add_host_keys(["ssh-ed25519 b"])
      expect(sa.host_keys).to eq ["ssh-ed25519 c"]
    end
  end

  describe "#check_for_new_host_keys" do
    rsa_key = OpenSSL::PKey::RSA.generate(2048)
    ecdsa_keys = Array.new(2) { OpenSSL::PKey::EC.generate("prime256v1") }
    ed25519_keys = Array.new(3) { Net::SSH::KeyFactory.load_data_private_key(SshKey.generate.private_key) }
    prove_request = "hostkeys-prove-00@openssh.com"

    let(:rsa_key) { rsa_key }
    let(:ecdsa_keys) { ecdsa_keys }
    let(:ed25519_keys) { ed25519_keys }
    let(:server_key_class) { Struct.new(:private_key, :blob, :str) }

    def server_key(type, index = 0)
      private_key, public_key = case type
      when :ed25519
        key = ed25519_keys.fetch(index)
        [key, key.public_key]
      when :rsa
        [rsa_key, rsa_key]
      when :ecdsa
        key = ecdsa_keys.fetch(index)
        [key, key]
      end
      blob = public_key.to_blob
      server_key_class.new(private_key, blob, "#{public_key.ssh_type} #{[blob].pack("m0")}")
    end

    def proof(key, sig_type, blob: key.blob)
      data = Net::SSH::Buffer.from(:string, "hostkeys-prove-00@openssh.com", :string, "test-session-id", :string, blob).to_s
      Net::SSH::Buffer.from(:string, sig_type, :string, key.private_key.ssh_do_sign(data, sig_type)).to_s
    end

    def expect_host_keys_session(offered, proof_response = nil)
      algorithms = instance_double(Net::SSH::Transport::Algorithms, session_id: "test-session-id")
      session = instance_double(Net::SSH::Connection::Session, transport: instance_double(Net::SSH::Transport::Session, algorithms:))
      handler = nil
      pending = []
      requests = []
      responses = [[false, nil]]
      responses << proof_response if proof_response

      expect(Net::SSH).to receive(:start).and_yield(session)
      expect(session).to receive(:on_global_request).with("hostkeys-00@openssh.com") { |&block| handler = block }
      allow(session).to receive(:send_global_request) do |*args, &block|
        requests << args
        pending << block
      end
      allow(session).to receive(:pending_requests).and_return(pending)
      expect(session).to receive(:loop) do |&running|
        expect(handler.call(Net::SSH::Buffer.from(*offered.flat_map { [:string, it] }), false)).to be false
        pending.shift.call(*responses.shift) while running.call
      end

      requests
    end

    before { sa.save_changes }

    it "adds new host keys the host proves it has" do
      known = server_key(:ed25519)
      rsa = server_key(:rsa)
      ecdsa = server_key(:ecdsa)
      unsupported = Net::SSH::Buffer.from(:string, "sk-ssh-ed25519@openssh.com", :string, "x").to_s
      sa.update(host_keys: [known.str])

      requests = expect_host_keys_session([known.blob, unsupported, rsa.blob, ecdsa.blob],
        [true, Net::SSH::Buffer.from(:string, proof(rsa, "rsa-sha2-512"), :string, proof(ecdsa, "ecdsa-sha2-nistp256"))])
      expect(Clog).to receive(:emit).with("sshable host keys added", {sshable_host_keys_added: {sshable: sa.ubid, keys: [rsa.str, ecdsa.str]}}).and_call_original

      sa.check_for_new_host_keys
      expect(requests).to eq [["keepalive@openssh.com"], [prove_request, :string, rsa.blob, :string, ecdsa.blob]]
      expect(sa.host_keys).to eq [known.str, rsa.str, ecdsa.str]
      expect(sa.reload.host_keys).to eq [known.str, rsa.str, ecdsa.str]
    end

    it "only adds host keys with valid proofs" do
      known = server_key(:ed25519)
      rsa = server_key(:rsa)
      bad_ed25519 = server_key(:ed25519, 1)
      ecdsa = server_key(:ecdsa)
      bad_ecdsa = server_key(:ecdsa, 1)
      unproven = server_key(:ed25519, 2)
      sa.update(host_keys: [known.str])

      expect_host_keys_session([known.blob, rsa.blob, bad_ed25519.blob, ecdsa.blob, bad_ecdsa.blob, unproven.blob],
        [true, Net::SSH::Buffer.from(
          # RSA key with a signature type that is not an RSA signature type
          :string, proof(rsa, "ssh-ed25519"),
          # Signature for a different blob, which raises when verified
          :string, proof(bad_ed25519, "ssh-ed25519", blob: known.blob),
          # Key with valid signature
          :string, proof(ecdsa, "ecdsa-sha2-nistp256"),
          # Non-RSA key with a signature type that does not match the key type
          :string, proof(bad_ecdsa, "ecdsa-sha2-nistp384"),
          # Missing signature for unproven
        )])

      sa.check_for_new_host_keys
      expect(sa.reload.host_keys).to eq [known.str, ecdsa.str]
    end

    it "does not add host keys if no proofs are valid" do
      known = server_key(:ed25519)
      ecdsa = server_key(:ecdsa)
      other_ecdsa = server_key(:ecdsa, 1)
      sa.update(host_keys: [known.str])

      expect_host_keys_session([known.blob, ecdsa.blob],
        [true, Net::SSH::Buffer.from(:string, proof(other_ecdsa, "ecdsa-sha2-nistp256", blob: ecdsa.blob))])
      expect(Clog).not_to receive(:emit)
      expect(sa).not_to receive(:add_host_keys)

      sa.check_for_new_host_keys
      expect(sa.reload.host_keys).to eq [known.str]
    end

    it "does not add host keys if the host does not respond successfully to the prove request" do
      known = server_key(:ed25519)
      ecdsa = server_key(:ecdsa)
      sa.update(host_keys: [known.str])

      requests = expect_host_keys_session([known.blob, ecdsa.blob], [false, nil])
      expect(sa).not_to receive(:add_host_keys)

      sa.check_for_new_host_keys
      expect(requests).to eq [["keepalive@openssh.com"], [prove_request, :string, ecdsa.blob]]
      expect(sa.reload.host_keys).to eq [known.str]
    end

    it "does not request proofs if the host does not offer a known host key" do
      known = server_key(:ed25519)
      ecdsa = server_key(:ecdsa)
      sa.update(host_keys: [known.str])

      requests = expect_host_keys_session([ecdsa.blob])
      expect(sa).not_to receive(:add_host_keys)

      sa.check_for_new_host_keys
      expect(requests).to eq [["keepalive@openssh.com"]]
      expect(sa.reload.host_keys).to eq [known.str]
    end

    it "does not request proofs if the host does not offer new host keys" do
      known = server_key(:ed25519)
      sa.update(host_keys: [known.str])

      requests = expect_host_keys_session([known.blob])
      expect(sa).not_to receive(:add_host_keys)

      sa.check_for_new_host_keys
      expect(requests).to eq [["keepalive@openssh.com"]]
      expect(sa.reload.host_keys).to eq [known.str]
    end

    it "does not attempt connection if the sshable has no host keys" do
      expect(sa).not_to receive(:start_fresh_session)
      sa.check_for_new_host_keys
      expect(sa.reload.host_keys).to be_nil
    end
  end

  describe "#cmd" do
    let(:session) { Net::SSH::Connection::Session.allocate }

    before do
      expect(sa).to receive(:connect).and_return(session).at_least(:once)
    end

    def simulate(cmd:, exit_status:, exit_signal:, stdout:, stderr:)
      allow(session).to receive(:loop).and_yield
      expect(session).to receive(:open_channel) do |&blk|
        chan = instance_spy(Net::SSH::Connection::Channel)
        allow(chan).to receive(:connection).and_return(session)
        expect(chan).to receive(:exec).with(cmd) do |&blk|
          chan2 = instance_spy(Net::SSH::Connection::Channel)
          expect(chan2).to receive(:on_request).with("exit-status") do |&blk|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(exit_status)
            blk.call(nil, buf)
          end

          expect(chan2).to receive(:on_request).with("exit-signal") do |&blk|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(exit_signal)
            blk.call(nil, buf)
          end
          expect(chan2).to receive(:on_data).and_yield(instance_double(Net::SSH::Connection::Channel), stdout)
          expect(chan2).to receive(:on_extended_data).and_yield(nil, 1, stderr)
          allow(chan2).to receive(:connection).and_return(session)

          blk.call(chan2, true)
        end
        blk.call(chan, true)
        chan
      end
    end

    it "can run a command" do
      [false, true].each do |repl_value|
        [false, true].each do |log_value|
          allow(described_class).to receive(:repl?).and_return(repl_value)
          if repl_value
            # Note that in the REPL, stdout and stderr get multiplexed
            # into stderr in real time, packet by packet.
            expect($stderr).to receive(:write).with("hello")
            expect($stderr).to receive(:write).with("world")
          end

          if log_value
            sa.instance_variable_set(:@connect_duration, 1.1)
            expect(Clog).to receive(:emit).with("ssh cmd execution", instance_of(Hash)) do |_, dat|
              if repl_value
                expect(dat[:ssh].slice(:stdout, :stderr)).to be_empty
              else
                expect(dat[:ssh].slice(:stdout, :stderr)).to eq({stdout: "hello", stderr: "world"})
              end
            end
          end
          simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
          expect(sa.cmd("echo hello", log: log_value, timeout: nil, _skip_command_checking: true)).to eq("hello")
        end
      end
    end

    it "raises an SshError with a non-zero exit status" do
      simulate(cmd: "exit 1", exit_status: 1, exit_signal: 127, stderr: "", stdout: "")
      expect { sa.cmd("exit 1", timeout: nil, _skip_command_checking: true) }.to raise_error Sshable::SshError, "command exited with an error: exit 1"
    end

    it "does not log a successful command when log: :on_error" do
      expect(Clog).not_to receive(:emit).with("ssh cmd execution", anything)
      simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
      expect(sa.cmd("echo hello", log: :on_error, timeout: nil, _skip_command_checking: true)).to eq("hello")
    end

    it "logs a failing command when log: :on_error" do
      expect(Clog).to receive(:emit).with("ssh cmd execution", instance_of(Hash))
      simulate(cmd: "exit 1", exit_status: 1, exit_signal: 127, stderr: "", stdout: "")
      expect { sa.cmd("exit 1", log: :on_error, timeout: nil, _skip_command_checking: true) }.to raise_error Sshable::SshError
    end

    it "raises an SshError with a nil exit status" do
      simulate(cmd: "exit 1", exit_status: nil, exit_signal: nil, stderr: "", stdout: "")
      expect { sa.cmd("exit 1", timeout: nil, _skip_command_checking: true) }.to raise_error Sshable::SshTimeout, "command timed out: exit 1"
    end

    it "supports custom timeout" do
      simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
      expect(sa.cmd("echo hello", log: false, timeout: 2, _skip_command_checking: true)).to eq("hello")
    end

    it "suports default timeout" do
      simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
      expect(sa.cmd("echo hello", log: false, _skip_command_checking: true)).to eq("hello")
    end

    it "supports default timeout based on thread apoptosis_at variable if no explicit timeout is given if variable is available" do
      Thread.current[:apoptosis_at] = Time.now + 60
      simulate(cmd: "echo hello", exit_status: 0, exit_signal: nil, stdout: "hello", stderr: "world")
      expect(sa.cmd("echo hello", log: false, _skip_command_checking: true)).to eq("hello")
    ensure
      Thread.current[:apoptosis_at] = nil
    end

    it "invalidates the cache if the session raises an error" do
      err = IOError.new("the party is over")
      expect(session).to receive(:open_channel).and_raise err
      expect(sa).to receive(:invalidate_cache_entry)
      expect { sa.cmd("irrelevant", _skip_command_checking: true) }.to raise_error err
    end
  end

  describe "#cmd with a caller-supplied session" do
    let(:session) { Net::SSH::Connection::Session.allocate }

    def simulate_on(sess, cmd:, exit_status:, stdout:)
      expect(sess).to receive(:open_channel) do |&blk|
        chan = instance_spy(Net::SSH::Connection::Channel)
        allow(chan).to receive(:connection).and_return(sess)
        expect(chan).to receive(:exec).with(cmd) do |&eblk|
          chan2 = instance_spy(Net::SSH::Connection::Channel)
          expect(chan2).to receive(:on_request).with("exit-status") do |&blk2|
            buf = instance_double(Net::SSH::Buffer)
            expect(buf).to receive(:read_long).and_return(exit_status)
            blk2.call(nil, buf)
          end
          expect(chan2).to receive(:on_request).with("exit-signal")
          expect(chan2).to receive(:on_data).and_yield(instance_double(Net::SSH::Connection::Channel), stdout)
          expect(chan2).to receive(:on_extended_data)
          allow(chan2).to receive(:connection).and_return(sess)
          eblk.call(chan2, true)
        end
        blk.call(chan, true)
        chan
      end
    end

    it "runs the command on the supplied session without opening a cached connection" do
      expect(sa).not_to receive(:connect)
      simulate_on(session, cmd: "echo hello", exit_status: 0, stdout: "hello")
      expect(sa.cmd("echo hello", timeout: nil, session:, _skip_command_checking: true)).to eq("hello")
    end

    it "does not invalidate the connection cache when the supplied session fails" do
      err = IOError.new("the party is over")
      expect(sa).not_to receive(:connect)
      expect(sa).not_to receive(:invalidate_cache_entry)
      expect(session).to receive(:open_channel).and_raise err
      expect { sa.cmd("irrelevant", session:, _skip_command_checking: true) }.to raise_error err
    end
  end

  describe "#cmd_json" do
    it "parses cmd output as JSON" do
      expect(sa).to receive(:_cmd).with("cat data.json").and_return('{"key": "value"}')
      expect(sa.cmd_json("cat data.json")).to eq({"key" => "value"})
    end
  end

  describe "daemonizer methods" do
    let(:unit_name) { "test_unit" }
    let(:run_command) { "sudo host/bin/setup-vm prep test_unit" }
    let(:stdin_data) { "secret_data" }

    it "calls cmd with the correct check command" do
      expect(sa).to receive(:_cmd).with("common/bin/daemonizer2 check test_unit")
      sa.d_check(unit_name)
    end

    it "calls cmd with the correct clean command" do
      expect(sa).to receive(:_cmd).with("common/bin/daemonizer2 clean test_unit")
      sa.d_clean(unit_name)
    end

    it "calls cmd with the correct restart command" do
      expect(sa).to receive(:_cmd).with("common/bin/daemonizer2 restart test_unit")
      sa.d_restart(unit_name)
    end

    it "calls cmd with the correct stop command" do
      expect(sa).to receive(:_cmd).with("common/bin/daemonizer2 stop test_unit")
      sa.d_stop(unit_name)
    end

    it "calls cmd with the correct run command and no stdin" do
      expect(sa).to receive(:_cmd).with("common/bin/daemonizer2 run test_unit sudo\\ host/bin/setup-vm\\ prep\\ test_unit", stdin: nil, log: true)
      sa.d_run(unit_name, run_command)
    end

    it "calls cmd with the correct run command and passes stdin" do
      expect(sa).to receive(:_cmd).with("common/bin/daemonizer2 run test_unit sudo\\ host/bin/setup-vm\\ prep\\ test_unit", stdin: stdin_data, log: true)
      sa.d_run(unit_name, run_command, stdin: stdin_data)
    end

    it "calls cmd with the correct journalctl command for the unit" do
      expect(sa).to receive(:_cmd).with("sudo journalctl -u test_unit --no-pager")
      sa.d_logs(unit_name)
    end

    it "calls cmd with the correct journalctl command when limiting the number of lines" do
      expect(sa).to receive(:_cmd).with("sudo journalctl -u test_unit -n 10 --no-pager")
      sa.d_logs(unit_name, lines: 10)
    end
  end
end
