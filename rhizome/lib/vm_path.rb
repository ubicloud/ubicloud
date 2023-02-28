# frozen_string_literal: true

require "shellwords"

class VmPath
  def initialize(vm_name)
    @vm_name = vm_name
  end

  def home(n)
    File.join("", "home", @vm_name, n)
  end

  %w[
    guest_mac
    ephemeral
    ipsec
    boot.raw
    meta-data
    network-config
    user-data
    cloudinit.img
  ].each do |file_name|
    method_name = file_name.tr(".-", "_")
    fail "BUG" if method_defined?(method_name)

    # Method producing a path, e.g. #user_data
    define_method method_name do
      home(file_name)
    end

    # Method producing a shell-quoted path, e.g. #q_user_data.
    quoted_method_name = "q_" + method_name
    fail "BUG" if method_defined?(quoted_method_name)
    define_method quoted_method_name do
      home(file_name).shellescape
    end

    # Method reading the file's contents, e.g. #read_user_data
    #
    # Trailing newlines are removed.
    read_method_name = "read_" + method_name
    fail "BUG" if method_defined?(read_method_name)
    define_method read_method_name do
      File.read(home(file_name)).chomp
    end

    # Method overwriting the file's contents, e.g. #write_user_data
    write_method_name = "write_" + method_name
    fail "BUG" if method_defined?(write_method_name)
    define_method write_method_name do |content|
      content += "\n" unless content.end_with?("\n")
      File.write(home(file_name), content)
    end
  end
end
