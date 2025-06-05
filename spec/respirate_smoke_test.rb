# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

num_processes = if (arg = ARGV.shift)
  num_partitions = Integer(arg).clamp(1, nil)
  partitioned = true if num_partitions > 1

  if (arg = ARGV.shift)
    Integer(arg).clamp(1, nil)
  else
    num_partitions
  end
else
  1
end

require_relative "../loader"

num_strands = 1000
seconds_allowed = 60

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

if ENV["CONSISTENT"]
  class Prog::Test
    def rand(x = nil)
      case x
      when range
        20
      when Integer
        10
      else
        0.5
      end
    end
  end
end

# Use Vm uuids, because they are random, while Strand uuids are timestamp based
# and will always be in the first partition
strands = Array.new(num_strands) { Strand.create(prog: "Test", label: "smoke_test_3", id: Vm.generate_uuid) }
ds = Strand.where(id: strands.map(&:id))

r, w = IO.pipe
output = +""
Thread.new do
  output << r.read(4096).to_s
end
time = Time.now

respirate_pids = Array.new(num_processes) do
  respirate_args = [(num_partitions - it).to_s] if partitioned
  Process.spawn("bin/respirate", *respirate_args, :in => :close, [:out, :err] => w)
end
respirate_pids.compact!

w.close

finished_ds = ds.where(label: "smoke_test_0")
deadline = Time.now + seconds_allowed
print(partitioned ? "#{num_processes}/#{num_partitions} partitioned: " : "#{num_processes} unpartitioned: ")
until (count = finished_ds.count) == num_strands || Time.now > deadline
  print count, " "
  sleep 1
end
printf("%0.3f seconds ", Time.now - time)

Process.kill(:TERM, *respirate_pids)
reap_queue = Queue.new
Thread.new do
  respirate_pids.each { Process.waitpid(it) }
  reap_queue.push(true)
end

reap_queue.pop(timeout: 3)

# puts "output:"
# puts output

finished_count = finished_ds.count
unless finished_count == num_strands
  puts
  raise "Only #{finished_count}/#{num_strands} strands finished processing within #{seconds_allowed} seconds"
end

unless output.length == num_strands * 3
  puts
  puts output
  raise "unexpected output length: #{output.length}"
end

(1..3).each do |n|
  unless output.count(n.to_s) == num_strands
    puts
    raise "Not all strands output expected information"
  end
end

puts "passed!"
