# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require_relative "../loader"

num_strands = 1000
seconds_allowed = 30

keep_strand_ids = Strand.select_map(&:id)
at_exit do
  delete_strand_ds = Strand
    .exclude(id: keep_strand_ids)
    .select(:id)

  Semaphore
    .where(strand_id: delete_strand_ds)
    .delete(force: true)

  delete_strand_ds.delete(force: true)
end

strands = Array.new(num_strands) { Strand.create(prog: "Test", label: "smoke_test_3") }
ds = Strand.where(id: strands.map(&:id))

r, w = IO.pipe
output = +""
Thread.new do
  output << r.read(4096).to_s
end
respirate_pid = Process.spawn("bin/respirate", :in => :close, [:out, :err] => w)
w.close

finished_ds = ds.where(label: "smoke_test_0")
deadline = Time.now + seconds_allowed
until finished_ds.count == num_strands || Time.now > deadline
  print "."
  sleep 1
end
puts

Process.kill(:TERM, respirate_pid)
sleep 1

# puts "output:"
# puts output

finished_count = finished_ds.count
unless finished_count == num_strands
  raise "Only #{finished_count}/#{num_strands} strands finished processing within #{seconds_allowed} seconds"
end

unless output.length == num_strands * 3
  raise "unexpected output length: #{output.length}"
end

(1..3).each do |n|
  unless output.count(n.to_s) == num_strands
    raise "Not all strands output expected information"
  end
end
