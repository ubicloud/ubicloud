# frozen_string_literal: true

RSpec.describe NetSsh do
  commands = [:command]

  if Config.unfrozen_test?
    commands << :prod_command

    it ".command raises for placeholder inside quotes" do
      expect { described_class.command("a ':c'", c: "a") }.to raise_error(NetSsh::PotentialInsecurity)
      expect { described_class.command('a ":c"', c: "a") }.to raise_error(NetSsh::PotentialInsecurity)
    end

    it ".command raises for unterminated quotes" do
      expect { described_class.command(":c '", c: "a") }.to raise_error(NetSsh::PotentialInsecurity)
      expect { described_class.command(':c "', c: "a") }.to raise_error(NetSsh::PotentialInsecurity)
      expect { described_class.command(":c 'a", c: "a") }.to raise_error(NetSsh::PotentialInsecurity)
      expect { described_class.command(':c "a', c: "a") }.to raise_error(NetSsh::PotentialInsecurity)
    end

    it ".command works with comments with '" do
      expect(described_class.command("# isn't it fun\n:c", c: "e f")).to eq "# isn't it fun\ne\\ f"
    end

    it ".command works for placeholders after quotes" do
      c = "e f"
      expect(described_class.command("'' :c a", c:)).to eq "'' e\\ f a"
      expect(described_class.command('"" :c', c:)).to eq "\"\" e\\ f"
      expect(described_class.command("\\' :c", c:)).to eq "\\' e\\ f"
      expect(described_class.command('\\" :c', c:)).to eq "\\\" e\\ f"
      expect(described_class.command("'\"' :c", c:)).to eq "'\"' e\\ f"
      expect(described_class.command('"\'" :c', c:)).to eq "\"'\" e\\ f"
      expect(described_class.command('"\\"" :c', c:)).to eq "\"\\\"\" e\\ f"
      expect(described_class.command("'\"'\"'\" :c", c:)).to eq "'\"'\"'\" e\\ f"
      expect(described_class.command("'\\\"'\"'\" :c", c:)).to eq "'\\\"'\"'\" e\\ f"
    end
  end

  commands.each do |command|
    it ".#{command} interpolates variables into string" do
      expect(described_class.send(command, "a :b :c d", b: 1, c: "e f")).to eq "a 1 e\\ f d"
    end

    it ".#{command} handles shelljoin interpolation" do
      expect(described_class.send(command, "a :b :shelljoin_c d", b: 1, shelljoin_c: ["e f", "g"])).to eq "a 1 e\\ f g d"
    end

    it ".#{command} returns string when not given keyword" do
      s = "a d"
      expect(described_class.send(command, s)).to be s
    end

    it ".#{command} raises for interpolated strings with keywords" do
      c = ":c"
      expect { described_class.send(command, "a :b #{c} d", b: 1, c: "e f") }.to raise_error(NetSsh::PotentialInsecurity)
      expect { described_class.send(command, "a #{c}") }.to raise_error(NetSsh::PotentialInsecurity)
    end

    it ".#{command} raises for non-strings" do
      o = Object.new
      expect { described_class.send(command, o) }.to raise_error(TypeError)
      expect { described_class.send(command, o, b: 1) }.to raise_error(TypeError)
    end
  end

  it ".combine combines multiple commands" do
    expect(described_class.combine("a b", "c d")).to eq "a b c d"
  end

  it ".combine supports a custom joiner" do
    expect(described_class.combine("a b", "c d", joiner: " && ")).to eq "a b && c d"
  end

  it ".combine raises for interpolated strings" do
    c = ":c"
    expect { described_class.combine("b", "a #{c}") }.to raise_error(NetSsh::PotentialInsecurity)
  end

  it "Net::SSH::Connection::Session#exec! raises if #_exec! is not mocked" do
    expect { Net::SSH::Connection::Session.allocate.exec!("a") }.to raise_error(NetSsh::MissingMock)
  end

  it "Sshable#cmd raises if #_cmd is not mocked" do
    expect { Sshable.new.cmd("a") }.to raise_error(NetSsh::MissingMock)
  end
end
