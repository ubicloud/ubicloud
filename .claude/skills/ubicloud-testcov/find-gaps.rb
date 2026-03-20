#!/usr/bin/env ruby
# frozen_string_literal: true

# Parses coverage/.resultset.json and prints every uncovered line and branch
# NOT inside a # :nocov: block.
#
# Output format (one record per line, tab-separated):
#   LINE   <file>  <lineno>
#   BRANCH <file>  <lineno>  <start_col>  <end_col>  <branch_type>
#
# Pipe into highlight-gaps.rb for a human-readable highlighted view.
#
# Usage (from project root):
#   ruby .claude/skills/ubicloud-testcov/find-gaps.rb
#   ruby .claude/skills/ubicloud-testcov/find-gaps.rb | ruby .claude/skills/ubicloud-testcov/highlight-gaps.rb

require "json"

def parse_loc(str)
  tokens = str.scan(/[^,\[\]\s]+/)
  { type: tokens[0], line: tokens[1].to_i, col: tokens[2].to_i,
    end_line: tokens[3].to_i, end_col: tokens[4].to_i }
end

resultset = File.join(__dir__, "../../../coverage/.resultset.json")
unless File.exist?(resultset)
  warn "No coverage/.resultset.json found. Run coverage first."
  exit 1
end

data = JSON.parse(File.read(resultset))

merged_cov = {}
data.values.each do |result|
  (result["coverage"] || {}).each do |file, file_data|
    merged_file = (merged_cov[file] ||= {})

    if (lines = file_data["lines"])
      merged_lines = (merged_file["lines"] ||= [])
      lines.each_with_index do |count, idx|
        next if count.nil?
        merged_lines[idx] = (merged_lines[idx] || 0) + count
      end
    end

    if (branches = file_data["branches"])
      merged_branches = (merged_file["branches"] ||= {})
      branches.each do |parent_str, children|
        merged_children = (merged_branches[parent_str] ||= {})
        children.each do |branch_str, count|
          next if count.nil?
          merged_children[branch_str] = (merged_children[branch_str] || 0) + count
        end
      end
    end
  end
end
cov = merged_cov
root = File.expand_path("../../..", __dir__)

cov.each do |file, file_data|
  next unless file.start_with?(root)
  next if file.include?("/coverage/") || file.include?("/spec/")

  file_lines = File.readlines(file) rescue next

  in_nocov    = false
  nocov_lines = []
  file_lines.each_with_index do |line, i|
    if line.strip =~ /#\s*:nocov:/
      in_nocov = !in_nocov
    elsif in_nocov
      nocov_lines << (i + 1)
    end
  end

  short = file.delete_prefix("#{root}/")

  # Uncovered lines
  (file_data["lines"] || []).each_with_index do |count, i|
    next unless count == 0
    lineno = i + 1
    next if nocov_lines.include?(lineno)
    puts "LINE\t#{short}\t#{lineno}"
  end

  # Uncovered branches
  (file_data["branches"] || {}).each do |_parent_str, children|
    children.each do |branch_str, count|
      next unless count == 0
      b = parse_loc(branch_str)
      next if nocov_lines.include?(b[:line])
      puts "BRANCH\t#{short}\t#{b[:line]}\t#{b[:col]}\t#{b[:end_col]}\t#{b[:type]}"
    end
  end
end
