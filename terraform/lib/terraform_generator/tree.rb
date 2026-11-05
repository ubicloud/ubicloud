# frozen_string_literal: true

require "fileutils"

# Tree keeps the module on disk in step with the render, which maps each
# generated file's path in the module to its text. Since git ignores the
# generated files, it cannot tell which of them an engineer has edited;
# the stamp in each file's header can.
class TerraformGenerator::Tree
  # A generated file begins with comment lines, the last of which ends in
  # the stamp. Neither their wording nor their number is checked, so that
  # a file written under an older header is still recognized.
  HEAD = /\A(?:\S+ .*\n)*?\S+ .*\bsha256:(\h{16})\n/

  def initialize(dir)
    @dir = dir
  end

  # Writes the render and returns the status each file had. Every status is
  # found before anything is written, so that if finding one raises,
  # nothing has been written.
  def write(files, force: false)
    compare(files).to_h do |path, (status, head)|
      case status
      when :new, :stale, :carried then put(path, files[path])
      when :edited then put(path, files[path]) if force
      when :orphan then File.delete(full(path)) if force || intact?(head)
      end
      [path, status]
    end
  end

  # Each edited file, with the text to diff it against: the render's body
  # under the file's header, so that the diff shows only what is left to
  # carry back. An edited orphan gets an empty body.
  def edits(files)
    compare(files).filter_map do |path, (status, head)|
      [path, head[0] + body(files[path])] if status == :edited || (status == :orphan && !intact?(head))
    end.to_h
  end

  private

  # The status of each file that the render gives or that has the generated
  # header, with the header it has on disk. Files are read as UTF-8,
  # because the render is UTF-8 and the default encoding follows the
  # locale. A file that is not valid UTF-8, such as the binary that go
  # build leaves here, would make the match raise, so it is taken to have
  # no header.
  def compare(files)
    disk = Dir.glob("**/*", base: @dir).select { File.file?(full(it)) }.to_h { [it, File.read(full(it), encoding: Encoding::UTF_8)] }
    heads = disk.transform_values { HEAD.match(it) if it.valid_encoding? }.compact
    (files.keys | heads.keys).sort.to_h { [it, [status(it, files[it], disk[it], heads[it]), heads[it]]] }
  end

  def status(path, text, disk, head)
    return :new unless disk
    return :unchanged if disk == text
    raise "#{full(path)} has no generated header, so the generator will not overwrite it; move it away" unless head
    return :orphan unless text
    if intact?(head) then :stale
    elsif head.post_match == body(text) then :carried
    else :edited
    end
  end

  def intact?(head) = head[1] == TerraformGenerator.stamp(head.post_match)

  def body(text) = text ? HEAD.match(text).post_match : ""

  # Write a temporary file and rename it into place, so that an interrupted
  # run cannot leave a half-written file.
  def put(path, text)
    FileUtils.mkdir_p(File.dirname(full(path)))
    File.write("#{full(path)}.tmp", text)
    File.rename("#{full(path)}.tmp", full(path))
  end

  def full(path) = File.join(@dir, path)
end
