# frozen_string_literal: true

RSpec.describe GithubRunnerMetrics do
  it "installs the guest writer as a service" do
    expect(described_class.install_command).to eq(<<~COMMAND)
      echo #{Base64.strict_encode64(described_class::GUEST_WRITER).shellescape} | base64 -d | sudo tee /usr/local/bin/ubicloud-metrics-writer > /dev/null
      sudo chmod 755 /usr/local/bin/ubicloud-metrics-writer
      echo #{Base64.strict_encode64(described_class::DISK_UNIT).shellescape} | base64 -d | sudo tee /etc/systemd/system/ubicloud-metrics-writer.service > /dev/null
      sudo systemctl daemon-reload
      sudo systemctl start ubicloud-metrics-writer.service
    COMMAND
  end
end
