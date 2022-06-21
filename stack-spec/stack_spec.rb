ENV['MT_NO_PLUGINS'] = '1' # Work around stupid autoloading of plugins
require 'minitest/global_expectations/autorun'

require 'fileutils'
require 'net/http'
require 'uri'
require 'find'

TEST_STACK_DIR = 'test-stack'.freeze
RAKE = ENV['RAKE'] || 'rake'
RACKUP = ENV['RACKUP'] || 'rackup'
SEQUEL = ENV['SEQUEL'] || 'sequel'

describe 'roda-sequel-stack' do
  after do
    FileUtils.remove_dir(TEST_STACK_DIR) if File.directory?(TEST_STACK_DIR)
  end

  def progress(object)
    if ENV['DEBUG']
      p object
    else
      print '.'
    end
  end

  if RUBY_ENGINE == 'jruby'
    JRUBY = ENV['JRUBY'] || 'jruby'
    db_url = 'jdbc:sqlite:db.sqlite3_test'
    def command(args)
      unless args[0] == 'git'
        args.unshift('-S')
        args.unshift(JRUBY)
      end
      progress(args)
      args
    end
  else
    db_url = 'sqlite://db.sqlite3_test'
    def command(args)
      progress(args)
      args
    end
  end

  def run_rackup
    read, write = IO.pipe
    args = [RACKUP, '-e', '$stderr.sync = $stdout.sync = true']
    command(args)
    pid = Process.spawn(*args, out: write, err: write)
    read.each_line do |line|
      progress(line)
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
    command(cmds)
    read, write = IO.pipe
    system(*cmds, out: write, err: write).tap{|x| unless x; write.close; p cmds; puts read.read; end}.must_equal true
    write.close
    progress(read.read)
    read.close
  end

  def rewrite(filename)
    File.binwrite(filename, yield(File.binread(filename)))
  end

  it 'should work after rake setup is run' do
    run_cmd("git", "clone", ".", TEST_STACK_DIR)

    Dir.chdir(TEST_STACK_DIR) do
      run_cmd(RAKE, 'setup[FooBarApp]')
      ENV['FOO_BAR_APP_DATABASE_URL'] = db_url

      files = []
      directories = []
      Find.find('.').each do |f|
        if File.directory?(f)
          Find.prune if f == './.git'
          directories << f
        else
          files << f
        end
      end

      directories.sort.must_equal  [
        ".", "./assets", "./assets/css", "./migrate", "./models", "./public", "./routes",
        "./spec", "./spec/model", "./spec/web", "./views"
      ]
      files.sort.must_equal [
        "./.env.rb", "./.gitignore", "./Gemfile", "./README.rdoc", "./Rakefile", "./app.rb",
        "./assets/css/app.scss", "./config.ru", "./db.rb", "./migrate/001_tables.rb",
        "./models.rb", "./models/model1.rb", "./routes/prefix1.rb", "./spec/coverage_helper.rb",
        "./spec/minitest_helper.rb", "./spec/model.rb", "./spec/model/model1_spec.rb",
        "./spec/model/spec_helper.rb", "./spec/web.rb", "./spec/web/prefix1_spec.rb",
        "./spec/web/spec_helper.rb", "./views/index.erb", "./views/layout.erb"
      ]

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
      rewrite('routes/prefix1.rb'){|s| s.sub("# /prefix1 branch handling", "r.get{view 'p1'}")}
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
      run_cmd(RAKE)
      run_cmd(RAKE, 'model_spec')
      run_cmd(RAKE, 'web_spec')

      unless RUBY_ENGINE == 'jruby'
        # Test running coverage
        run_cmd(RAKE, 'spec_cov')
        coverage = File.binread('coverage/index.html')
        coverage.must_include('lines covered')
        coverage.must_include('lines missed')
        coverage.must_include('branches covered')
        coverage.must_include('branches missed')
      end
    end
  end
end
