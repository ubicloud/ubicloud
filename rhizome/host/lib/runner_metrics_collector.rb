# frozen_string_literal: true

# Reads and deletes the files runner metrics agents write. Each agent writes
# only validated entries, into its VM's directory under ROOT, which rhizome
# can read but the VM can't.
class RunnerMetricsCollector
  ROOT = "/var/lib/runner-metrics"
  VM_NAME = /\Avm[0-9a-z]{6}\z/
  FILE_NAME = /\A\d+\.jsonl\z/

  def initialize(root = ROOT)
    @root = root
  end

  # Returns a "<vm> <file> <json>" line per entry.
  def read(vm_names)
    out = +""
    vm_names.each do |vm_name|
      dir = vm_dir(vm_name)
      next unless File.directory?(dir)

      files = Dir.children(dir).select { |file| FILE_NAME.match?(file) }.sort!
      files.each do |file|
        File.foreach(File.join(dir, file), chomp: true) { |line| out << "#{vm_name} #{file} #{line}\n" }
      end
    end
    out
  end

  # Deletes the files named by "<vm> <file>" lines.
  def ack(lines)
    lines.each do |line|
      vm_name, file = line.split(" ", 2)
      fail "invalid file name: #{file.inspect}" unless FILE_NAME.match?(file)

      File.unlink(File.join(vm_dir(vm_name), file))
    end
  end

  def vm_dir(vm_name)
    fail "invalid VM name: #{vm_name.inspect}" unless VM_NAME.match?(vm_name)

    File.join(@root, vm_name)
  end
end
