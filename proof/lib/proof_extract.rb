# frozen_string_literal: true

require "json"
require "yaml"

module ProofExtract
  class Error < StandardError; end

  # Entry in the source map: which input file and line produced a given output line.
  SourceLoc = Struct.new(:file, :line)

  # Unicode → TLA+ ASCII translation for # TLA pragmas.
  # Pragmas use unicode for LLM readability; proof-tool converts to
  # valid TLA+ ASCII for the model checker.
  UNICODE_TO_TLA = {
    "\u2200" => "\\A",          # ∀ → \A
    "\u2203" => "\\E",          # ∃ → \E
    "\u2208" => "\\in",         # ∈ → \in
    "\u2209" => "\\notin",      # ∉ → \notin
    "\u222A" => "\\union",      # ∪ → \union
    "\u2229" => "\\intersect",  # ∩ → \intersect
    "\u2286" => "\\subseteq",   # ⊆ → \subseteq
    "\u00AC" => "~",            # ¬ → ~
    "\u2260" => "#",            # ≠ → #
    "\u2227" => "/\\",          # ∧ → /\
    "\u2228" => "\\/",          # ∨ → \/
    "\u21D2" => "=>",           # ⇒ → =>
    "\u27E8" => "<<",           # ⟨ → <<
    "\u27E9" => ">>",           # ⟩ → >>
    "\u21A6" => "|->"          # ↦ → |->
  }.freeze

  # Translate unicode mathematical operators to TLA+ ASCII.
  def self.unicode_to_tla(line)
    UNICODE_TO_TLA.each do |unicode, ascii|
      line = line.gsub(unicode) { ascii }
    end
    line
  end

  # TLA+ ASCII → Unicode translation (reverse of UNICODE_TO_TLA).
  # Ordered longest-first to avoid partial matches (e.g. \notin before \in).
  # \A and \E require trailing space to avoid matching inside identifiers.
  ASCII_TO_UNICODE = [
    ["\\intersect", "\u2229"],  # ∩
    ["\\subseteq", "\u2286"],   # ⊆
    ["\\notin", "\u2209"],      # ∉
    ["\\union", "\u222A"],      # ∪
    ["|->", "\u21A6"],          # ↦
    ["\\in", "\u2208"],         # ∈
    ["/\\", "\u2227"],          # ∧
    ["\\/", "\u2228"],          # ∨
    ["\\A ", "\u2200 "],        # ∀ (with trailing space)
    ["\\E ", "\u2203 "],        # ∃ (with trailing space)
    ["<<", "\u27E8"],           # ⟨
    [">>", "\u27E9"],           # ⟩
    ["=>", "\u21D2"],           # ⇒
    [" # ", " \u2260 "],        # ≠ (space-padded to avoid comments)
    ["~", "\u00AC"]            # ¬
  ].freeze

  # Translate TLA+ ASCII operators to Unicode for pretty-printing.
  def self.tla_to_unicode(line)
    ASCII_TO_UNICODE.each do |ascii, unicode|
      line = line.gsub(ascii, unicode)
    end
    line
  end

  # Extract TLA+ lines from a .rb file by scanning for # TLA pragmas.
  #
  # Line mode:   # TLA <content>     → extracted (unicode translated)
  #              # TLA               → blank line
  #              # TLA:<key> <value> → metadata (skipped, except :module for scoping)
  # Block mode:  # TLA:begin ... # TLA:end → verbatim (unicode translated)
  #
  # When +mod+ is non-nil, only lines within a matching # TLA:module scope
  # are extracted.  A scope starts at "# TLA:module <name>" and ends at the
  # next "# TLA:module" or end of file.  Files with no # TLA:module line
  # are always included (they belong to whatever proof uses them).
  #
  # When +unicode+ is true, pragmas keep their original Unicode operators
  # instead of being translated to TLA+ ASCII.
  #
  # Returns an array of [content_string, source_line_number] pairs.
  def self.extract_rb(path, mod: nil, unicode: false)
    lines = File.readlines(path, chomp: true)
    result = []
    in_block = false
    block_start = nil
    has_module_decl = mod && lines.any? { it.lstrip.start_with?("# TLA:module") }
    in_scope = !has_module_decl  # no module decls in file → always in scope

    lines.each_with_index do |line, idx|
      lineno = idx + 1
      stripped = line.lstrip

      if in_block
        if stripped == "# TLA:end"
          in_block = false
          block_start = nil
        elsif in_scope
          result << [unicode ? line : unicode_to_tla(line), lineno]
        end
      elsif stripped == "# TLA:begin"
        in_block = true
        block_start = lineno
      elsif stripped.start_with?("# TLA")
        rest = stripped.delete_prefix("# TLA")
        if rest.empty?
          # Bare "# TLA" → blank line
          result << ["", lineno] if in_scope
        elsif rest.start_with?(":")
          # Metadata line — check for module scope
          if rest.start_with?(":module")
            name = rest.delete_prefix(":module").strip
            in_scope = mod.nil? || name == mod
          end
          # All metadata lines (module, invariant, verified) are skipped from output
        elsif rest.start_with?(" ")
          # "# TLA <content>" → extract and translate
          result << [unicode ? rest[1..] : unicode_to_tla(rest[1..]), lineno] if in_scope
        end
      end
    end

    if in_block
      raise Error, "#{path}:#{block_start}: unmatched # TLA:begin (no # TLA:end found)"
    end

    result
  end

  # Read a .tla file verbatim.
  #
  # When +unicode+ is true, translates ASCII TLA+ operators to Unicode.
  #
  # Returns an array of [content_string, source_line_number] pairs.
  def self.read_tla(path, unicode: false)
    File.readlines(path, chomp: true).each_with_index.map do |line, idx|
      [unicode ? tla_to_unicode(line) : line, idx + 1]
    end
  end

  # Assemble multiple input files into a single TLA+ output.
  #
  # When +mod+ is non-nil, .rb extraction is scoped to that module name.
  # When +unicode+ is true, output uses Unicode operators (for reading, not TLC).
  # When +backrefs+ is true, section headers show which source file each
  # block came from.
  #
  # Returns [output_lines, source_map] where source_map maps 1-based output
  # line numbers to SourceLoc structs.
  def self.assemble(paths, mod: nil, unicode: false, backrefs: false)
    output_lines = []
    source_map = {}

    paths.each do |path|
      ext = File.extname(path)
      pairs = case ext
      when ".tla"
        read_tla(path, unicode:)
      when ".rb"
        extract_rb(path, mod:, unicode:)
      else
        raise Error, "#{path}: unknown file extension '#{ext}' (expected .tla or .rb)"
      end

      next if pairs.empty?

      if backrefs
        first_line = pairs.first[1]
        output_lines << "\\* \u2500\u2500 #{path}:#{first_line} \u2500\u2500"
        source_map[output_lines.size] = SourceLoc.new(path, first_line)
      end

      pairs.each do |content, src_line|
        output_lines << content
        out_lineno = output_lines.size
        source_map[out_lineno] = SourceLoc.new(path, src_line)
      end
    end

    [output_lines, source_map]
  end

  # Serialize the source map to JSON (keyed by output line number as string).
  def self.source_map_to_json(source_map)
    hash = {}
    source_map.each do |out_line, loc|
      hash[out_line.to_s] = {"file" => loc.file, "line" => loc.line}
    end
    JSON.pretty_generate(hash)
  end

  # Look up an output line number in a saved source map file.
  def self.trace(map_path, line_number)
    data = JSON.parse(File.read(map_path))
    entry = data[line_number.to_s]
    unless entry
      raise Error, "line #{line_number} not found in #{map_path} (valid range: #{data.keys.map(&:to_i).minmax.join("-")})"
    end
    "#{entry["file"]}:#{entry["line"]}"
  end

  # Rewrite TLC output, annotating line references with source locations.
  # Matches patterns like "line 84, col 3 ... of module DnsRecordSync"
  # and appends the mapped source file:line.
  def self.annotate_tlc_output(text, map_path)
    return text unless File.exist?(map_path)
    data = JSON.parse(File.read(map_path))

    text.gsub(/line (\d+), col \d+ to line \d+, col \d+ of module \w+/) do |match|
      line_num = $1
      entry = data[line_num]
      if entry
        "#{match}  (#{entry["file"]}:#{entry["line"]})"
      else
        match
      end
    end
  end

  # Load proof declarations from tla.yaml.
  #
  # Returns a hash: { "Name" => { dir:, config:, sources:, configs: {} } }
  # with symbol keys for each proof's attributes.
  # Backward compat: a top-level "quick:" key is treated as configs: { quick: ... }.
  def self.load_prooffile(path = "tla.yaml")
    raise Error, "#{path}: not found" unless File.exist?(path)
    data = YAML.safe_load_file(path)
    data.transform_values do |raw|
      configs = if raw["configs"]
        raw["configs"].transform_values { |v| v || {} }
      elsif raw["quick"]
        {"quick" => raw["quick"]}
      else
        {}
      end
      {
        dir: raw["dir"],
        config: raw["config"],
        sources: raw["sources"],
        configs:
      }
    end
  end

  # Patch a .cfg file with constant overrides.
  # Returns the modified content as a string.
  def self.override_cfg(cfg_path, overrides)
    text = File.read(cfg_path)
    overrides.each do |key, value|
      text = text.gsub(/^(\s*#{Regexp.escape(key.to_s)}\s*=\s*).*$/, "\\1#{value}")
    end
    text
  end
end
