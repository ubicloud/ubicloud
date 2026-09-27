# frozen_string_literal: true

require_relative "../lib/guest_postgres_manager"
require_relative "../lib/slot"

RSpec.describe GuestPostgresManager do
  subject(:pg) { described_class.new(slot) }

  let(:slot) { Slot.new(2, ip6_block: "2a01:4f8:120:9208:2::/79") }

  describe ".install" do
    it "installs psql, which it configures PostgreSQL with" do
      expect(described_class).to receive(:r).with("apt-get", "update")
      expect(described_class).to receive(:r).with("apt-get", "-y", "install", "postgresql-client")
      described_class.install
    end
  end

  describe "#ready?" do
    # One end is what the host dials, the other plays the guest.
    let(:pair) { UNIXSocket.pair }
    let(:host_end) { pair[0] }
    let(:guest_end) { pair[1] }

    before do
      allow(Socket).to receive(:tcp)
        .with(slot.public_ip6, 5432, "fd00:b1c:ffff:2::1", nil, connect_timeout: 0.2)
        .and_return(host_end)
    end

    after { guest_end.close unless guest_end.closed? }

    it "is true when the server asks the client to authenticate" do
      guest_end.write("R")
      expect(pg.ready?).to be true
      length, version = guest_end.read(8).unpack("NN")
      expect(version).to eq(196_608)
      expect(guest_end.read(length - 8)).to eq("user\0postgres\0database\0postgres\0\0")
    end

    it "is false while the server is still starting up" do
      guest_end.write("E\0\0\0\x20SFATAL\0C57P03\0Mthe database system is starting up\0\0")
      expect(pg.ready?).to be false
    end

    it "is true when the server is up but refuses this particular client" do
      guest_end.write("E\0\0\0\x20SFATAL\0C28000\0Mno pg_hba.conf entry\0\0")
      expect(pg.ready?).to be true
    end

    it "is false on anything else" do
      guest_end.write("N")
      expect(pg.ready?).to be false
    end

    it "is false when nothing answers" do
      allow(host_end).to receive(:wait_readable).with(1).and_return(nil)
      expect(pg.ready?).to be false
    end

    it "is false when nothing is listening yet" do
      allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
      expect(pg.ready?).to be false
    end

    it "closes the connection whatever the answer" do
      guest_end.write("R")
      pg.ready?
      expect(host_end).to be_closed
    end
  end

  describe "#wait_ready" do
    before { allow(pg).to receive(:sleep) }

    it "polls until the server accepts connections" do
      answers = [false, false, true]
      allow(pg).to receive(:ready?) { answers.shift }
      expect(pg).to receive(:sleep).with(0.01).twice
      pg.wait_ready(timeout: 10)
      expect(answers).to be_empty
    end

    it "gives up on a server that never comes up" do
      allow(pg).to receive(:ready?).and_return(false)
      expect { pg.wait_ready(timeout: 0) }.to raise_error(GuestPostgresManager::Error, /within 0s/)
    end
  end

  describe "#configure" do
    def sql_for(payload)
      sent = nil
      expect(pg).to receive(:run_sql) { |sql| sent = sql }
      pg.configure(payload)
      sent
    end

    it "sets the superuser password" do
      expect(sql_for({"superuser_password" => "pw"})).to eq("ALTER ROLE postgres PASSWORD E'pw';\n")
    end

    it "creates the database only when it is missing" do
      expect(sql_for({"database" => "app"})).to eq(
        "SELECT 'CREATE DATABASE ' || quote_ident(E'app') " \
        "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = E'app') \\gexec\n",
      )
    end

    it "leaves the postgres database alone" do
      expect(pg).not_to receive(:run_sql)
      pg.configure({"database" => "postgres"})
    end

    it "runs nothing when there is nothing to change" do
      expect(pg).not_to receive(:run_sql)
      pg.configure({})
    end

    it "quotes whatever it is given, backslashes included" do
      expect(sql_for({"superuser_password" => "it's a \\ test"})).to eq("ALTER ROLE postgres PASSWORD E'it''s a \\\\ test';" + "\n")
    end

    it "refuses a NUL, which no literal can carry" do
      expect { pg.configure({"superuser_password" => "a\0b"}) }.to raise_error(GuestPostgresManager::Error, /NUL/)
    end
  end

  describe "running SQL" do
    it "runs psql inside the slot's namespace, with the statements on stdin" do
      expect(pg).to receive(:r).with("ip", "netns", "exec", "emslot0002", "env", "PGCONNECT_TIMEOUT=10",
        "psql", "-X", "-q", "-w", "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=terse",
        "-h", "fd00:b1c:5b0c::2", "-p", "5432", "-U", "postgres", "-d", "postgres", "-f", "-",
        stdin: "ALTER ROLE postgres PASSWORD E'secret';\n")
      pg.configure({"superuser_password" => "secret"})
    end
  end
end
