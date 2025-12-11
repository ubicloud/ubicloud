# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RotateSshKey do
  subject(:rsk) {
    described_class.new(Strand.new(prog: "RotateSshKey", stack: [{"subject_id" => sshable.id}]))
  }

  let(:keypair_1) { SshKey.generate }
  let(:keypair_2) { SshKey.generate }
  let(:sshable) {
    Sshable.create(host: "test.localhost", raw_private_key_1: keypair_1.keypair, raw_private_key_2: keypair_2.keypair)
  }
  let(:sess) { Net::SSH::Connection::Session.allocate }

  describe "#compute_authorized_keys" do
    context "when unix_user is rhizome" do
      it "returns only Sshable keys (ignores operator keys)" do
        result = rsk.compute_authorized_keys(operator_keys: "ssh-ed25519 OPERATOR operator@host")
        expect(result).to eq("#{keypair_1.public_key}\n#{keypair_2.public_key}")
      end

      it "returns only Sshable keys when no operator keys" do
        result = rsk.compute_authorized_keys(operator_keys: nil)
        expect(result).to eq("#{keypair_1.public_key}\n#{keypair_2.public_key}")
      end
    end

    context "when unix_user is not rhizome" do
      let(:sshable) {
        Sshable.create(host: "test.localhost", unix_user: "ubi", raw_private_key_1: keypair_1.keypair, raw_private_key_2: keypair_2.keypair)
      }

      it "returns operator keys first, then Sshable keys" do
        result = rsk.compute_authorized_keys(operator_keys: "ssh-ed25519 OPERATOR operator@host")
        expect(result).to eq("ssh-ed25519 OPERATOR operator@host\n#{keypair_1.public_key}\n#{keypair_2.public_key}")
      end

      it "returns only Sshable keys when no operator keys" do
        result = rsk.compute_authorized_keys(operator_keys: nil)
        expect(result).to eq("#{keypair_1.public_key}\n#{keypair_2.public_key}")
      end
    end
  end

  describe "#new_private_key" do
    it "returns the private key from raw_private_key_2" do
      expect(rsk.new_private_key).to start_with("-----BEGIN OPENSSH PRIVATE KEY-----")
    end
  end

  describe "#start" do
    let(:sshable) {
      Sshable.create(host: "test.localhost", raw_private_key_1: keypair_1.keypair)
    }

    it "generates new key and hops to create_test_user" do
      expect { rsk.start }.to hop("create_test_user")
      sshable.reload
      expect(sshable.raw_private_key_2).not_to be_nil
    end
  end

  describe "#create_test_user" do
    it "creates test user and hops to install_keys_to_test_user" do
      expect(rsk.sshable).to receive(:_cmd).with("sudo adduser --disabled-password --gecos '' rhizome_rotate").ordered
      expect(rsk.sshable).to receive(:_cmd).with("sudo install -d -o rhizome_rotate -g rhizome_rotate -m 0700 /home/rhizome_rotate/.ssh").ordered
      expect { rsk.create_test_user }.to hop("install_keys_to_test_user")
    end

    it "continues if user already exists" do
      expect(rsk.sshable).to receive(:_cmd).with("sudo adduser --disabled-password --gecos '' rhizome_rotate").and_raise(
        Sshable::SshError.new("adduser", "", "adduser: The user `rhizome_rotate' already exists.", 1, nil)
      ).ordered
      expect(rsk.sshable).to receive(:_cmd).with("sudo install -d -o rhizome_rotate -g rhizome_rotate -m 0700 /home/rhizome_rotate/.ssh").ordered
      expect { rsk.create_test_user }.to hop("install_keys_to_test_user")
    end

    it "raises if adduser fails with unexpected error" do
      expect(rsk.sshable).to receive(:_cmd).with("sudo adduser --disabled-password --gecos '' rhizome_rotate").and_raise(
        Sshable::SshError.new("adduser", "", "adduser: some other error", 1, nil)
      )
      expect { rsk.create_test_user }.to raise_error(Sshable::SshError)
    end
  end

  describe "#install_keys_to_test_user" do
    let(:sshable) {
      Sshable.create(host: "test.localhost", unix_user: "ubi", raw_private_key_1: keypair_1.keypair, raw_private_key_2: keypair_2.keypair)
    }

    it "installs computed keys to test user and hops to test_login_to_test_user" do
      expect(rsk).to receive(:compute_authorized_keys).and_return("test-authorized-keys")
      expect(rsk.sshable).to receive(:_cmd).with(<<CMD)
set -ueo pipefail
echo test-authorized-keys | sudo install -m 0600 -o rhizome_rotate -g rhizome_rotate /dev/stdin /home/rhizome_rotate/.ssh/authorized_keys.new
sudo sync /home/rhizome_rotate/.ssh/authorized_keys.new
sudo mv /home/rhizome_rotate/.ssh/authorized_keys.new /home/rhizome_rotate/.ssh/authorized_keys
sudo sync /home/rhizome_rotate/.ssh
CMD
      expect { rsk.install_keys_to_test_user }.to hop("test_login_to_test_user")
    end
  end

  describe "#test_login_to_test_user" do
    it "tests SSH login to test user with new key and hops to promote_keys_to_target_user" do
      expect(Net::SSH).to receive(:start).with("test.localhost", "rhizome_rotate", anything).and_yield(sess)
      expect(sess).to receive(:_exec!).with("echo test user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("test user login successful\n", 0)
      )
      expect { rsk.test_login_to_test_user }.to hop("promote_keys_to_target_user")
    end

    it "fails if exit status not zero" do
      expect(Net::SSH).to receive(:start).and_yield(sess)
      expect(sess).to receive(:_exec!).and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("error", 1)
      )
      expect { rsk.test_login_to_test_user }.to raise_error RuntimeError, "Unexpected exit status: 1"
    end

    it "fails if output not expected" do
      expect(Net::SSH).to receive(:start).and_yield(sess)
      expect(sess).to receive(:_exec!).and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("wrong output\n", 0)
      )
      expect { rsk.test_login_to_test_user }.to raise_error RuntimeError, "Unexpected output: wrong output\n"
    end
  end

  describe "#promote_keys_to_target_user" do
    it "copies keys to target user and hops to verify_target_user_login" do
      expect(rsk.sshable).to receive(:_cmd).with(<<CMD)
set -ueo pipefail
sudo install -m 0600 -o rhizome -g rhizome /home/rhizome_rotate/.ssh/authorized_keys /home/rhizome/.ssh/authorized_keys.new
sudo sync /home/rhizome/.ssh/authorized_keys.new
sudo mv /home/rhizome/.ssh/authorized_keys.new /home/rhizome/.ssh/authorized_keys
sudo sync /home/rhizome/.ssh
CMD
      expect { rsk.promote_keys_to_target_user }.to hop("verify_target_user_login")
    end
  end

  describe "#verify_target_user_login" do
    it "verifies target user login and hops to retire_old_key_in_database" do
      expect(Net::SSH).to receive(:start).with("test.localhost", "rhizome", anything).and_yield(sess)
      expect(sess).to receive(:_exec!).with("echo target user login successful").and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("target user login successful\n", 0)
      )
      expect { rsk.verify_target_user_login }.to hop("retire_old_key_in_database")
    end

    it "fails if exit status not zero" do
      expect(Net::SSH).to receive(:start).and_yield(sess)
      expect(sess).to receive(:_exec!).and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("error", 1)
      )
      expect { rsk.verify_target_user_login }.to raise_error RuntimeError, "Unexpected exit status: 1"
    end

    it "fails if output not expected" do
      expect(Net::SSH).to receive(:start).and_yield(sess)
      expect(sess).to receive(:_exec!).and_return(
        Net::SSH::Connection::Session::StringWithExitstatus.new("wrong output\n", 0)
      )
      expect { rsk.verify_target_user_login }.to raise_error RuntimeError, "Unexpected output: wrong output\n"
    end
  end

  describe "#retire_old_key_in_database" do
    it "retires old keys on database and hops to delete_test_user" do
      expect { rsk.retire_old_key_in_database }.to hop("delete_test_user")
      sshable.reload
      expect(sshable.raw_private_key_1).to eq(keypair_2.keypair)
      expect(sshable.raw_private_key_2).to be_nil
    end

    it "fails if no record changes" do
      sshable.update(raw_private_key_2: nil)
      expect { rsk.retire_old_key_in_database }.to raise_error RuntimeError, "Unexpected number of changed records: 0"
    end
  end

  describe "#delete_test_user" do
    it "deletes test user and pops success" do
      expect(rsk.sshable).to receive(:_cmd).with("sudo userdel -r rhizome_rotate")
      expect { rsk.delete_test_user }.to exit({"msg" => "key rotated successfully"})
    end

    it "continues if user does not exist" do
      expect(rsk.sshable).to receive(:_cmd).with("sudo userdel -r rhizome_rotate").and_raise(
        Sshable::SshError.new("userdel", "", "userdel: user 'rhizome_rotate' does not exist", 6, nil)
      )
      expect { rsk.delete_test_user }.to exit({"msg" => "key rotated successfully"})
    end

    it "raises if userdel fails with unexpected error" do
      expect(rsk.sshable).to receive(:_cmd).with("sudo userdel -r rhizome_rotate").and_raise(
        Sshable::SshError.new("userdel", "", "userdel: some other error", 1, nil)
      )
      expect { rsk.delete_test_user }.to raise_error(Sshable::SshError)
    end
  end
end
