# frozen_string_literal: true

# Reads and deletes runner metrics agent files as root. The VM user owns their
# directories, so paths are opened without following links.
class RunnerMetricsCollector
  VM_NAME = /\Avm[0-9a-z]{6}\z/
  FILE_NAME = /\A\d{8}T\d{15}\.jsonl\z/
  MAX_FILES_PER_VM = 12
  MAX_BYTES_PER_VM = 1024 * 1024
  OPEN_FLAGS = File::RDONLY | File::NOFOLLOW | File::NONBLOCK

  def initialize(vm_root = "/vm")
    @vm_root = vm_root
  end

  # Returns "<vm> <file>" per file, then "<vm> <file> <json>" per entry.
  def read(vm_names)
    out = +""
    vm_names.each do |vm_name|
      with_done_dir(vm_name) do |dir|
        budget = MAX_BYTES_PER_VM
        Dir.children(dir).select { |file| FILE_NAME.match?(file) }.sort.first(MAX_FILES_PER_VM).each do |file|
          break if budget <= 0
          next unless (content = read_file("#{dir}/#{file}", budget))

          budget -= content.bytesize
          out << "#{vm_name} #{file}\n"
          content.each_line { |line| out << "#{vm_name} #{file} #{line.chomp}\n" }
        end
      end
    end
    out
  end

  # Deletes the files named by "<vm> <file>" lines.
  def ack(lines)
    lines.map(&:split).group_by(&:first).each do |vm_name, pairs|
      with_done_dir(vm_name) do |dir|
        pairs.each do |_, file|
          fail "invalid file name: #{file.inspect}" unless FILE_NAME.match?(file)

          begin
            File.unlink("#{dir}/#{file}")
          rescue Errno::ENOENT
            nil
          end
        end
      end
    end
  end

  def fd_path(io)
    "/proc/self/fd/#{io.fileno}"
  end

  def with_done_dir(vm_name)
    fail "invalid VM name: #{vm_name.inspect}" unless VM_NAME.match?(vm_name)

    dirs = []
    begin
      dir = open_dir("#{@vm_root}/#{vm_name}", dirs) &&
        open_dir("#{fd_path(dirs.last)}/metrics", dirs) &&
        open_dir("#{fd_path(dirs.last)}/done", dirs)
      yield fd_path(dir) if dir
    ensure
      dirs.each(&:close)
    end
  end

  def open_dir(path, opened)
    opened << (dir = File.open(path, OPEN_FLAGS))
    dir if dir.stat.directory?
  rescue Errno::ENOENT, Errno::ELOOP
    nil
  end

  def read_file(path, max_bytes)
    File.open(path, OPEN_FLAGS) do |file|
      stat = file.stat
      file.read(max_bytes) || "" if stat.file? && stat.nlink == 1
    end
  rescue Errno::ENOENT, Errno::ELOOP
    nil
  end
end
