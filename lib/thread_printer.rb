# frozen_string_literal: true

module ThreadPrinter
  def self.run
    Thread.list.each do |thread|
      puts "Thread: #{thread.inspect}"
      puts thread.backtrace&.join("\n")
    end
  end
end
