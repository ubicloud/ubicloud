#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads find-gaps.rb output from stdin and renders it with ANSI highlighting.
#
# LINE records:   full source line shown with red background.
# BRANCH records: source line shown with the uncovered expression highlighted
#                 in yellow, labelled with the branch type (:else, :then, etc.).
#
# Usage:
#   ruby .claude/skills/ubicloud-testcov/find-gaps.rb | ruby .claude/skills/ubicloud-testcov/highlight-gaps.rb

RESET     = "\e[0m"
BOLD      = "\e[1m"
DIM       = "\e[2m"
RED       = "\e[31m"
RED_BG    = "\e[41;97m"
YELLOW_BG = "\e[43;30m"

root = File.expand_path("../../..", __dir__)

# Group records by file, preserving order
by_file = {}
$stdin.each_line do |raw|
  fields = raw.chomp.split("\t")
  kind   = fields[0]
  file   = fields[1]
  next unless kind && file
  (by_file[file] ||= []) << fields
end

if by_file.empty?
  puts "\n#{BOLD}No gaps found — coverage is clean.#{RESET}\n"
  exit 0
end

by_file.each do |file, records|
  abs_path   = File.join(root, file)
  file_lines = File.readlines(abs_path) rescue []

  puts "\n#{BOLD}#{file}#{RESET}"

  records.sort_by { |f| f[2].to_i }.each do |fields|
    kind   = fields[0]
    lineno = fields[2].to_i
    src    = (file_lines[lineno - 1] || "").rstrip

    case kind
    when "LINE"
      tag     = "#{RED}LINE  #{RESET}"
      display = "#{RED_BG}#{src}#{RESET}"

    when "BRANCH"
      start_col   = fields[3].to_i
      end_col     = fields[4].to_i
      branch_type = fields[5].to_s   # :else, :then, :when, etc.

      s = start_col.clamp(0, src.length)
      e = end_col.clamp(s, src.length)

      highlighted =
        if s < e
          src[0...s] + YELLOW_BG + src[s...e] + RESET + src[e..]
        else
          "#{YELLOW_BG}#{src}#{RESET}"
        end

      display = "#{highlighted}   #{DIM}← #{branch_type}#{RESET}"
      tag     = "#{BOLD}BRANCH#{RESET}"
    else
      next
    end

    puts "  #{DIM}#{lineno.to_s.rjust(4)}#{RESET}  #{tag}  #{display}"
  end
end

puts
