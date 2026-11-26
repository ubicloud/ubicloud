# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/qmp"

RSpec.describe Qmp do
  subject(:qmp) { described_class.new(socket_path, 1) }

  let(:dir) { Dir.mktmpdir }
  let(:socket_path) { File.join(dir, "qmp.sock") }
  let!(:server) { UNIXServer.new(socket_path) }
  let(:greeting) { {"QMP" => {"version" => {}, "capabilities" => []}} }

  after do
    server.close
    FileUtils.remove_entry(dir)
  end

  def serve(*replies)
    received = []
    thread = Thread.new do
      conn = server.accept
      conn.write(JSON.generate(greeting) + "\n")
      replies.each do |reply|
        received << JSON.parse(conn.gets)
        reply.each { |message| conn.write(JSON.generate(message) + "\n") }
      end
      conn.close
    end
    [thread, received]
  end

  it "sends system_powerdown after negotiating capabilities" do
    thread, received = serve([{"return" => {}}], [{"event" => "POWERDOWN"}, {"return" => {}}])
    expect(qmp.system_powerdown).to eq({})
    thread.join
    expect(received).to eq([{"execute" => "qmp_capabilities"}, {"execute" => "system_powerdown"}])
  end

  it "raises when a command fails" do
    thread, _ = serve([{"error" => {"class" => "CommandNotFound"}}])
    expect { qmp.system_powerdown }.to raise_error(Qmp::Error, /qmp_capabilities failed/)
    thread.join
  end

  it "raises on an unexpected greeting" do
    greeting.replace({"foo" => 1})
    thread, _ = serve
    expect { qmp.system_powerdown }.to raise_error(Qmp::Error, /unexpected QMP greeting/)
    thread.join
  end

  it "raises when the connection closes" do
    thread, _ = serve([{"return" => {}}], [])
    expect { qmp.system_powerdown }.to raise_error(Qmp::Error, "QMP connection closed")
    thread.join
  end

  it "raises when QEMU does not respond in time" do
    qmp = described_class.new(socket_path, 0.1)
    expect { qmp.system_powerdown }.to raise_error(Qmp::Error, "QMP timed out after 0.1 seconds")
  end

  it "raises when a response exceeds the size limit" do
    qmp = described_class.new(socket_path, 1, 10)
    thread = Thread.new do
      conn = server.accept
      conn.write("x" * 11)
      conn.read
      conn.close
    end
    expect { qmp.system_powerdown }.to raise_error(Qmp::Error, "QMP response size limit exceeded")
    thread.join
  end
end
