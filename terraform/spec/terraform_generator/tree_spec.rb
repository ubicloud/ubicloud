# frozen_string_literal: true

require "tmpdir"

RSpec.describe TerraformGenerator::Tree do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:tree) { described_class.new(@dir) }

  def gen(body, comment = "//") = TerraformGenerator.stamped(comment, body)

  def head(body, comment = "//") = gen(body, comment).delete_suffix(body)

  # A generated file whose body an engineer changed from body to edit.
  def edited(body, edit, comment = "//") = head(body, comment) + edit

  def disk(files)
    files.each do |path, text|
      FileUtils.mkdir_p(File.dirname(at(path)))
      File.write(at(path), text)
    end
  end

  def at(path) = File.join(@dir, path)

  def read(path) = File.read(at(path), encoding: Encoding::UTF_8)

  def listing = Dir.glob("**/*", base: @dir).select { File.file?(at(it)) }

  describe "#write" do
    it "writes a new file, and leaves an unchanged one alone, modification time included" do
      disk("same_gen.go" => gen("\nsame café\n"))
      File.utime(0, 0, at("same_gen.go"))
      files = {"internal/new_gen.go" => gen("\nnew\n"), "same_gen.go" => gen("\nsame café\n")}
      expect(tree.write(files)).to eq("internal/new_gen.go" => :new, "same_gen.go" => :unchanged)
      expect(listing).to eq %w[internal/new_gen.go same_gen.go]
      expect(read("internal/new_gen.go")).to eq files["internal/new_gen.go"]
      expect(File.mtime(at("same_gen.go"))).to eq Time.at(0)
    end

    it "rewrites a stale file, whose body is as the generator wrote it, under any header" do
      disk("thing_gen.go" => gen("\nold\n"), "other_gen.go" => "// An older header\n// of two lines\n// sha256:#{TerraformGenerator.stamp("\nnew\n")}\n\nnew\n")
      expect(tree.write({"thing_gen.go" => gen("\nnew\n"), "other_gen.go" => gen("\nnew\n")})).to eq("other_gen.go" => :stale, "thing_gen.go" => :stale)
      expect([read("thing_gen.go"), read("other_gen.go")]).to eq [gen("\nnew\n")] * 2
    end

    it "keeps an edited file, whose stamp no longer matches its body, unless forced" do
      disk("thing_gen.go" => edited("\nold\n", "\nmine\n"))
      expect(tree.write({"thing_gen.go" => gen("\nnew\n")})).to eq("thing_gen.go" => :edited)
      expect(read("thing_gen.go")).to eq edited("\nold\n", "\nmine\n")
      expect(tree.write({"thing_gen.go" => gen("\nnew\n")}, force: true)).to eq("thing_gen.go" => :edited)
      expect(read("thing_gen.go")).to eq gen("\nnew\n")
    end

    it "restamps a carried file, whose edit the render now reproduces" do
      disk("thing_gen.go" => edited("\nold\n", "\nnew\n"))
      expect(tree.write({"thing_gen.go" => gen("\nnew\n")})).to eq("thing_gen.go" => :carried)
      expect(read("thing_gen.go")).to eq gen("\nnew\n")
    end

    it "deletes an orphan, in either comment form, unless it is edited and not forced" do
      disk("gone_gen.go" => gen("\ngone\n"), "examples/gone/resource.tf" => gen("\ngone\n", "#"), "examples/kept/resource.tf" => edited("\nkept\n", "\nmine\n", "#"))
      expect(tree.write({})).to eq("examples/gone/resource.tf" => :orphan, "examples/kept/resource.tf" => :orphan, "gone_gen.go" => :orphan)
      expect(listing).to eq %w[examples/kept/resource.tf]
      expect(tree.write({}, force: true)).to eq("examples/kept/resource.tf" => :orphan)
      expect(listing).to eq []
    end

    it "leaves alone a file without the generated header, and refuses to overwrite one, writing nothing" do
      disk("main.go" => "package main\n", "terraform-provider-ubicloud" => "\x7fELF\xff\n".b, "thing_gen.go" => "package provider\n")
      expect(tree.write({"other_gen.go" => gen("\nother\n")})).to eq("other_gen.go" => :new)
      expect { tree.write({"a_gen.go" => gen("\na\n"), "thing_gen.go" => gen("\nthing\n")}) }
        .to raise_error(RuntimeError, "#{at("thing_gen.go")} has no generated header, so the generator will not overwrite it; move it away")
      expect(listing).to eq %w[main.go other_gen.go terraform-provider-ubicloud thing_gen.go]
      expect(read("thing_gen.go")).to eq "package provider\n"
    end
  end

  describe "#edits" do
    it "gives each edited file the render's body under its header, and an edited orphan an empty body" do
      disk(
        "edited_gen.go" => edited("\nold\n", "\nmine\n"),
        "carried_gen.go" => edited("\nold\n", "\nnew\n"),
        "stale_gen.go" => gen("\nold\n"),
        "gone_gen.go" => gen("\ngone\n"),
        "kept_gen.go" => edited("\nkept\n", "\nmine\n"),
      )
      files = %w[edited carried stale new].to_h { ["#{it}_gen.go", gen("\nnew\n")] }
      expect(tree.edits(files)).to eq("edited_gen.go" => "#{head("\nold\n")}\nnew\n", "kept_gen.go" => head("\nkept\n"))
      expect(listing).to eq %w[carried_gen.go edited_gen.go gone_gen.go kept_gen.go stale_gen.go]
    end
  end
end
