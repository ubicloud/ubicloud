ENV['MT_NO_PLUGINS'] = '1' # Work around stupid autoloading of plugins
require_relative '../spec/warnings_helper'
require 'minitest/global_expectations/autorun'

require 'fileutils'
require 'net/http'
require 'uri'

TEST_STACK_DIR = 'test-stack'.freeze
RAKE = ENV['RAKE'] || 'rake'
RACKUP = ENV['RACKUP'] || 'rackup'
SEQUEL = ENV['SEQUEL'] || 'sequel'

describe 'roda-sequel-stack' do
  after do
    FileUtils.remove_dir(TEST_STACK_DIR) if File.directory?(TEST_STACK_DIR)
  end

  def run_rackup
    print '.'
    read, write = IO.pipe
    pid = Process.spawn(RACKUP, '-e', '$stderr.sync = $stdout.sync = true', out: write, err: write)
    read.each_line do |line|
      break if line =~ /Use Ctrl-C to stop|WEBrick::HTTPServer#start/
    end

    Net::HTTP.get(URI('http://127.0.0.1:9292/')).must_include 'Hello World!'
    Net::HTTP.get(URI('http://127.0.0.1:9292/prefix1')).must_include 'Model1: M1'
  ensure
    if pid
      Process.kill(:INT, pid)
      Process.wait(pid)
    end
    read.close if read
    write.close if write
  end

  # Run command capturing stderr/stdout
  def run_cmd(*cmds)
    print '.'
    read, write = IO.pipe
    system(*cmds, out: write, err: write).tap{|x| unless x; write.close; p cmds; puts read.read; end}.must_equal true
    write.close
    read.read
    read.close
  end

  def rewrite(filename)
    File.binwrite(filename, yield(File.binread(filename)))
  end

  it 'should work after rake setup is run' do
    run_cmd("git", "clone", ".", TEST_STACK_DIR)

    Dir.chdir(TEST_STACK_DIR) do
      system(RAKE, 'setup[FooBarApp]')
      db_url = ENV['FOO_BAR_APP_DATABASE_URL'] = 'sqlite://db.sqlite3'

      rewrite('migrate/001_tables.rb') do |s|
        s.sub("primary_key :id", "primary_key :id; String :name")
      end

      # Test migrations
      run_cmd(RAKE, 'test_up')
      run_cmd(RAKE, 'test_down')
      run_cmd(RAKE, 'test_bounce')
      run_cmd(RAKE, 'dev_up')
      run_cmd(RAKE, 'dev_down')
      run_cmd(RAKE, 'dev_bounce')
      run_cmd(RAKE, 'prod_up')
      
      Dir.mkdir('views/prefix1')
      File.binwrite('views/prefix1/p1.erb', "<p>Model1: <%= Model1.first.name %></p>")
      rewrite('routes/prefix1.rb'){|s| s.sub("set_view_subdir 'prefix1'", "set_view_subdir 'prefix1'\nr.get{view 'p1'}")}
      run_cmd(SEQUEL, db_url, '-c', "DB[:model1s].insert(name: 'M1')")

      # Test basic running
      run_rackup

      # Test annotation
      run_cmd(RAKE, 'annotate')

      # Test running with refrigerator
      rewrite('config.ru') do |s|
        s.sub(/^#freeze_core/, "freeze_core").
          gsub("#require", "require").
          sub('#Gem', 'Gem')
      end
      run_rackup

      # Test running specs
      File.link('db.sqlite3', 'db.sqlite3_test')
      ENV['FOO_BAR_APP_DATABASE_URL'] +=  '_test'
      run_cmd(RAKE)
      run_cmd(RAKE, 'model_spec')
      run_cmd(RAKE, 'web_spec')
    end
  end
end
