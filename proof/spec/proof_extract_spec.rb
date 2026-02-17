# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

RSpec.describe ProofExtract do
  def write_tmp(name, content)
    path = File.join(@tmpdir, name)
    File.write(path, content)
    path
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  describe ".unicode_to_tla" do
    it "translates all unicode operators" do
      input = "∀ x ∈ S : ∃ y ∈ S : x ∪ y ∩ z ⊆ w ∧ ¬a ∨ b ⇒ c ≠ d ⟨e⟩ f ↦ g ∉ h"
      result = described_class.unicode_to_tla(input)
      expect(result).to eq("\\A x \\in S : \\E y \\in S : x \\union y \\intersect z \\subseteq w /\\ ~a \\/ b => c # d <<e>> f |-> g \\notin h")
    end
  end

  describe ".tla_to_unicode" do
    it "translates all ASCII TLA+ operators to unicode" do
      input = "\\A x \\in S : \\E y \\in S : x \\union y \\intersect z \\subseteq w /\\ ~a \\/ b => c # d <<e>> f |-> g \\notin h"
      result = described_class.tla_to_unicode(input)
      expect(result).to eq("\u2200 x \u2208 S : \u2203 y \u2208 S : x \u222A y \u2229 z \u2286 w \u2227 \u00ACa \u2228 b \u21D2 c \u2260 d \u27E8e\u27E9 f \u21A6 g \u2209 h")
    end

    it "is the inverse of unicode_to_tla" do
      original = "\u2200 x \u2208 S : x \u222A y \u2227 \u00ACz"
      ascii = described_class.unicode_to_tla(original)
      roundtrip = described_class.tla_to_unicode(ascii)
      expect(roundtrip).to eq(original)
    end
  end

  describe ".extract_rb" do
    it "extracts line-mode pragmas with unicode translation" do
      path = write_tmp("a.rb", <<~RUBY)
        def foo
        end
        # TLA Foo(x) == x ∧ TRUE
      RUBY
      result = described_class.extract_rb(path)
      expect(result).to eq([["Foo(x) == x /\\ TRUE", 3]])
    end

    it "extracts bare # TLA as blank line" do
      path = write_tmp("a.rb", <<~RUBY)
        # TLA Foo == TRUE
        # TLA
        # TLA Bar == FALSE
      RUBY
      result = described_class.extract_rb(path)
      expect(result.map(&:first)).to eq(["Foo == TRUE", "", "Bar == FALSE"])
    end

    it "skips metadata lines" do
      path = write_tmp("a.rb", <<~RUBY)
        # TLA:module Spec
        # TLA:invariant Safety
        # TLA:verified 1000 states
        # TLA Foo == TRUE
      RUBY
      result = described_class.extract_rb(path)
      expect(result.map(&:first)).to eq(["Foo == TRUE"])
    end

    it "extracts block mode with unicode translation" do
      path = write_tmp("a.rb", <<~RUBY)
        # TLA:begin
        Foo == x ∧ TRUE
        # TLA:end
      RUBY
      result = described_class.extract_rb(path)
      expect(result).to eq([["Foo == x /\\ TRUE", 2]])
    end

    it "raises on unmatched TLA:begin" do
      path = write_tmp("a.rb", <<~RUBY)
        # TLA:begin
        Foo == TRUE
      RUBY
      expect { described_class.extract_rb(path) }
        .to raise_error(ProofExtract::Error, /unmatched # TLA:begin/)
    end

    it "ignores lines that are not TLA pragmas" do
      path = write_tmp("a.rb", <<~RUBY)
        def foo; end
        x = 1
      RUBY
      expect(described_class.extract_rb(path)).to eq([])
    end

    it "ignores # TLA followed by non-space non-colon" do
      path = write_tmp("a.rb", "# TLAfoo\n")
      expect(described_class.extract_rb(path)).to eq([])
    end

    describe "module scoping" do
      it "extracts all pragmas when mod is nil" do
        path = write_tmp("a.rb", <<~RUBY)
          # TLA:module Alpha
          # TLA A == 1
          # TLA:module Beta
          # TLA B == 2
        RUBY
        result = described_class.extract_rb(path)
        expect(result.map(&:first)).to eq(["A == 1", "B == 2"])
      end

      it "filters to matching module scope" do
        path = write_tmp("a.rb", <<~RUBY)
          # TLA:module Alpha
          # TLA A == 1
          # TLA:module Beta
          # TLA B == 2
        RUBY
        result = described_class.extract_rb(path, mod: "Alpha")
        expect(result.map(&:first)).to eq(["A == 1"])
      end

      it "includes all pragmas from files without module decls" do
        path = write_tmp("a.rb", <<~RUBY)
          # TLA A == 1
          # TLA B == 2
        RUBY
        result = described_class.extract_rb(path, mod: "Whatever")
        expect(result.map(&:first)).to eq(["A == 1", "B == 2"])
      end

      it "skips out-of-scope block content" do
        path = write_tmp("a.rb", <<~RUBY)
          # TLA:module Other
          # TLA:begin
          InBlock == TRUE
          # TLA:end
        RUBY
        result = described_class.extract_rb(path, mod: "Mine")
        expect(result).to eq([])
      end

      it "skips out-of-scope blank lines and content lines" do
        path = write_tmp("a.rb", <<~RUBY)
          # TLA:module Other
          # TLA
          # TLA X == 1
        RUBY
        result = described_class.extract_rb(path, mod: "Mine")
        expect(result).to eq([])
      end
    end
  end

  describe ".extract_rb with unicode: true" do
    it "keeps unicode operators without translating to ASCII" do
      path = write_tmp("a.rb", <<~RUBY)
        # TLA Foo(x) == x \u2227 TRUE
      RUBY
      result = described_class.extract_rb(path, unicode: true)
      expect(result).to eq([["Foo(x) == x \u2227 TRUE", 1]])
    end

    it "keeps unicode in block mode without translating" do
      path = write_tmp("a.rb", <<~RUBY)
        # TLA:begin
        Foo == x \u2227 TRUE
        # TLA:end
      RUBY
      result = described_class.extract_rb(path, unicode: true)
      expect(result).to eq([["Foo == x \u2227 TRUE", 2]])
    end
  end

  describe ".read_tla" do
    it "reads .tla file verbatim with line numbers" do
      path = write_tmp("a.tla", "Foo == TRUE\nBar == FALSE\n")
      result = described_class.read_tla(path)
      expect(result).to eq([["Foo == TRUE", 1], ["Bar == FALSE", 2]])
    end

    it "translates ASCII to unicode when unicode: true" do
      path = write_tmp("a.tla", "/\\ x \\in S\n")
      result = described_class.read_tla(path, unicode: true)
      expect(result).to eq([["\u2227 x \u2208 S", 1]])
    end
  end

  describe ".assemble" do
    it "assembles .tla and .rb files with source map" do
      tla = write_tmp("h.tla", "---- MODULE Test ----\n")
      rb = write_tmp("m.rb", "# TLA Foo == TRUE\n")

      lines, smap = described_class.assemble([tla, rb])
      expect(lines).to eq(["---- MODULE Test ----", "Foo == TRUE"])
      expect(smap[1].file).to eq(tla)
      expect(smap[1].line).to eq(1)
      expect(smap[2].file).to eq(rb)
      expect(smap[2].line).to eq(1)
    end

    it "passes mod through to extract_rb" do
      rb = write_tmp("m.rb", <<~RUBY)
        # TLA:module A
        # TLA X == 1
        # TLA:module B
        # TLA Y == 2
      RUBY
      lines, = described_class.assemble([rb], mod: "B")
      expect(lines).to eq(["Y == 2"])
    end

    it "raises on unknown file extension" do
      path = write_tmp("x.txt", "hi\n")
      expect { described_class.assemble([path]) }
        .to raise_error(ProofExtract::Error, /unknown file extension/)
    end

    it "adds back-reference headers at file transitions when backrefs: true" do
      tla = write_tmp("h.tla", "/\\ x \\in S\n")
      rb = write_tmp("m.rb", "# TLA Foo == TRUE\n")

      lines, = described_class.assemble([tla, rb], backrefs: true)
      expect(lines[0]).to match(/\u2500\u2500 .*h\.tla:1/)
      expect(lines[1]).to eq("/\\ x \\in S")
      expect(lines[2]).to match(/\u2500\u2500 .*m\.rb:1/)
      expect(lines[3]).to eq("Foo == TRUE")
    end

    it "outputs unicode with back-references in pretty mode" do
      tla = write_tmp("h.tla", "/\\ x \\in S\n")
      rb = write_tmp("m.rb", "# TLA Foo \u2227 TRUE\n")

      lines, = described_class.assemble([tla, rb], unicode: true, backrefs: true)
      expect(lines[0]).to match(/\u2500\u2500 .*h\.tla:1/)
      expect(lines[1]).to eq("\u2227 x \u2208 S")
      expect(lines[2]).to match(/\u2500\u2500 .*m\.rb:1/)
      expect(lines[3]).to eq("Foo \u2227 TRUE")
    end

    it "skips back-reference header for empty file sections" do
      rb = write_tmp("empty.rb", "def foo; end\n")
      tla = write_tmp("h.tla", "Foo == TRUE\n")

      lines, = described_class.assemble([rb, tla], backrefs: true)
      expect(lines[0]).to match(/\u2500\u2500 .*h\.tla:1/)
      expect(lines[1]).to eq("Foo == TRUE")
    end
  end

  describe ".source_map_to_json" do
    it "serializes source map as JSON" do
      smap = {1 => ProofExtract::SourceLoc.new("a.rb", 5)}
      json = described_class.source_map_to_json(smap)
      parsed = JSON.parse(json)
      expect(parsed).to eq({"1" => {"file" => "a.rb", "line" => 5}})
    end
  end

  describe ".trace" do
    it "looks up a line in the source map" do
      map_path = write_tmp("test.tla.map", JSON.generate({"3" => {"file" => "a.rb", "line" => 10}}))
      expect(described_class.trace(map_path, 3)).to eq("a.rb:10")
    end

    it "raises on missing line" do
      map_path = write_tmp("test.tla.map", JSON.generate({"1" => {"file" => "a.rb", "line" => 1}}))
      expect { described_class.trace(map_path, 99) }
        .to raise_error(ProofExtract::Error, /line 99 not found/)
    end
  end

  describe ".annotate_tlc_output" do
    it "annotates TLC line references with source locations" do
      map_path = write_tmp("test.tla.map", JSON.generate({"42" => {"file" => "dns_zone.rb", "line" => 31}}))
      text = "Error: line 42, col 3 to line 45, col 60 of module DnsRecordSync"
      result = described_class.annotate_tlc_output(text, map_path)
      expect(result).to include("(dns_zone.rb:31)")
    end

    it "returns text unchanged when map file does not exist" do
      text = "some output"
      expect(described_class.annotate_tlc_output(text, "/nonexistent/map")).to eq(text)
    end

    it "leaves unmatched line references unchanged" do
      map_path = write_tmp("test.tla.map", JSON.generate({"1" => {"file" => "a.rb", "line" => 1}}))
      text = "line 999, col 1 to line 999, col 10 of module Foo"
      expect(described_class.annotate_tlc_output(text, map_path)).to eq(text)
    end
  end

  describe ".load_prooffile" do
    it "loads proof declarations with configs map" do
      path = write_tmp("tla.yaml", <<~YAML)
        MyProof:
          dir: proof/my
          config: proof/my/MyProof.cfg
          sources:
            - proof/my/header.tla
            - model/my.rb
          configs:
            quick:
              MaxOps: 1
            full:
              MaxOps: 4
              Servers: '{"s1", "s2"}'
      YAML
      result = described_class.load_prooffile(path)
      expect(result).to eq({
        "MyProof" => {
          dir: "proof/my",
          config: "proof/my/MyProof.cfg",
          sources: ["proof/my/header.tla", "model/my.rb"],
          configs: {
            "quick" => {"MaxOps" => 1},
            "full" => {"MaxOps" => 4, "Servers" => '{"s1", "s2"}'}
          }
        }
      })
    end

    it "treats legacy quick: as configs: { quick: ... }" do
      path = write_tmp("tla.yaml", <<~YAML)
        MyProof:
          dir: proof/my
          config: proof/my/MyProof.cfg
          sources:
            - proof/my/header.tla
          quick:
            MaxOps: 1
      YAML
      result = described_class.load_prooffile(path)
      expect(result["MyProof"][:configs]).to eq({"quick" => {"MaxOps" => 1}})
    end

    it "defaults configs to empty hash" do
      path = write_tmp("tla.yaml", <<~YAML)
        MyProof:
          dir: proof/my
          config: proof/my/MyProof.cfg
          sources:
            - proof/my/header.tla
      YAML
      result = described_class.load_prooffile(path)
      expect(result["MyProof"][:configs]).to eq({})
    end

    it "raises when file not found" do
      expect { described_class.load_prooffile("/nonexistent/tla.yaml") }
        .to raise_error(ProofExtract::Error, /not found/)
    end
  end

  describe ".override_cfg" do
    it "patches constant values in a .cfg file" do
      cfg = write_tmp("test.cfg", <<~CFG)
        SPECIFICATION Spec
        CONSTANTS
          MaxOps = 4
          Xacts = {0, 1}
        INVARIANT TypeOK
      CFG
      result = described_class.override_cfg(cfg, {"MaxOps" => 1})
      expect(result).to include("MaxOps = 1")
      expect(result).to include("Xacts = {0, 1}")
    end
  end
end
