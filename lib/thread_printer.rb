# frozen_string_literal: true

module ThreadPrinter
  def self.run
    now = Time.now
    puts "--BEGIN THREAD DUMP, #{now}"
    Thread.list.each do |thread|
      puts "Thread: #{thread.inspect}"

      if (created_at = thread[:created_at])
        puts "Created at: #{created_at}, #{now - created_at} ago"
      end

      puts thread.backtrace&.join("\n")
    end
    puts "--END THREAD DUMP, #{now}"
  end
end
