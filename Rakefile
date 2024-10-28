# frozen_string_literal: true

require "sequel"

auto_parallel_tests = nil
auto_parallel_tests_file = ".auto-parallel-tests"

# Migrate
migrate = lambda do |env, version, db: nil|
  ENV["RACK_ENV"] = env
  require "bundler/setup"
  Bundler.setup
  require "logger"
  require_relative "db"
  Sequel.extension :migration

  db ||= DB
  db.extension :pg_enum

  db.loggers << Logger.new($stdout) if db.loggers.empty?
  Sequel::Migrator.apply(db, "migrate", version)

  # Check if the alternate-user password hash user needs to run
  # migrations.  It's desirable to avoid always connecting to run
  # migrations, since, almost always, there will be nothing to do and
  # it gluts output.
  case db[<<SQL].get
SELECT count(*)
FROM pg_class
WHERE relnamespace = 'public'::regnamespace AND relname = 'account_password_hashes'
SQL
  when 0
    user = db.get(Sequel.lit("current_user"))
    ph_user = "#{user}_password"

    # NB: this grant/revoke cannot be transaction-isolated, so, in
    # sensitive settings, it would be good to check role access.
    db["GRANT CREATE ON SCHEMA public TO ?", ph_user.to_sym].get
    Sequel.postgres(**db.opts.merge(user: ph_user)) do |ph_db|
      ph_db.loggers << Logger.new($stdout) if ph_db.loggers.empty?
      Sequel::Migrator.run(ph_db, "migrate/ph", table: "schema_migrations_password")
    end
    db["REVOKE ALL ON SCHEMA public FROM ?", ph_user.to_sym].get
  when 1
    # Already ran the "ph" migration as the alternate user.  This
    # branch is taken nearly all the time in a production situation.
  else
    fail "BUG: account_password_hashes table probing query should return 0 or 1"
  end
end

desc "Migrate test database to latest version"
task :test_up do
  migrate.call("test", nil)
end

desc "Migrate test database down. If VERSION isn't given, migrates to all the way down."
task :test_down do
  version = ENV["VERSION"].to_i || 0
  migrate.call("test", version)
end

desc "Migrate development database to latest version"
task :dev_up do
  migrate.call("development", nil)
end

desc "Migrate development database down. If VERSION isn't given, migrates to all the way down."
task :dev_down do
  version = ENV["VERSION"].to_i || 0
  migrate.call("development", version)
end

desc "Migrate production database to latest version"
task :prod_up do
  migrate.call("production", nil)
end

# Database setup

nproc = lambda do
  # Limit to 6 processes, as higher number results in more time
  `(nproc 2> /dev/null) || sysctl -n hw.logicalcpu`.to_i.clamp(1, 6).to_s
end

desc "Setup database"
task :setup_database, [:env, :parallel] do |_, args|
  raise "env must be test or dev" if !["test", "development"].include?(args[:env])
  raise "parallel can only be used in test" if args[:parallel] && args[:env] != "test"
  File.binwrite(auto_parallel_tests_file, "1") if args[:parallel] && !File.file?(auto_parallel_tests_file)

  database_count = args[:parallel] ? nproc.call.to_i : 1
  threads = []
  database_count.times do |i|
    threads << Thread.new do
      puts "Creating database #{i}..."
      database_name = "clover_#{args[:env]}#{args[:parallel] ? (i + 1) : ""}"
      `dropdb --if-exists -U postgres #{database_name}`
      `createdb -U postgres -O clover #{database_name}`
      `psql -U postgres -c 'CREATE EXTENSION citext; CREATE EXTENSION btree_gist;' #{database_name}`
      db = Sequel.connect("postgres:///#{database_name}?user=clover")
      migrate.call(args[:env], nil, db: db)
    end
  end

  threads.each(&:join)
end

desc "Generate a new .env.rb"
task :overwrite_envrb do
  require "securerandom"

  File.write(".env.rb", <<ENVRB)
# frozen_string_literal: true

case ENV["RACK_ENV"] ||= "development"
when "test"
  ENV["CLOVER_SESSION_SECRET"] ||= "#{SecureRandom.base64(64)}"
  ENV["CLOVER_DATABASE_URL"] ||= "postgres:///clover_test\#{ENV["TEST_ENV_NUMBER"]}?user=clover"
  ENV["CLOVER_COLUMN_ENCRYPTION_KEY"] ||= "#{SecureRandom.base64(32)}"
else
  ENV["CLOVER_SESSION_SECRET"] ||= "#{SecureRandom.base64(64)}"
  ENV["CLOVER_DATABASE_URL"] ||= "postgres:///clover_development?user=clover"
  ENV["CLOVER_COLUMN_ENCRYPTION_KEY"] ||= "#{SecureRandom.base64(32)}"
end
ENVRB
end

# Specs

desc "Run specs in with coverage in unfrozen mode, and without coverage in frozen mode"
task default: [:coverage, :frozen_spec]

rspec = lambda do |env|
  sh(env.merge("RACK_ENV" => "test", "FORCE_AUTOLOAD" => "1"), "bundle", "exec", "rspec", "spec")
end

turbo_tests = lambda do |env|
  sh(env.merge("RACK_ENV" => "test", "FORCE_AUTOLOAD" => "1"), "bundle", "exec", "turbo_tests", "-r", "./spec/suppress_pending", "-n", nproc.call)
end

spec = lambda do |env|
  if auto_parallel_tests.nil?
    auto_parallel_tests = File.file?(auto_parallel_tests_file) && File.binread(auto_parallel_tests_file) == "1"
  end

  block = auto_parallel_tests ? turbo_tests : rspec
  block.call(env)
end

desc "Run specs with coverage"
task "coverage" => [:coverage_spec]

{
  "sspec" => [" in serial", rspec],
  "pspec" => [" in parallel", turbo_tests],
  "spec" => ["", spec]
}.each do |task_suffix, (desc_suffix, block)|
  desc "Run specs#{desc_suffix}"
  task task_suffix do
    block.call({})
  end

  desc "Run specs#{desc_suffix} with frozen core, Database, and models (similar to production)"
  task "frozen_#{task_suffix}" do
    block.call("CLOVER_FREEZE_CORE" => "1", "CLOVER_FREEZE_MODELS" => "1")
  end

  desc "Run specs#{desc_suffix} with frozen core"
  task "frozen_core_#{task_suffix}" do
    block.call("CLOVER_FREEZE_CORE" => "1")
  end

  desc "Run specs#{desc_suffix} with frozen Database and models"
  task "frozen_db_model_#{task_suffix}" do
    block.call("CLOVER_FREEZE_MODELS" => "1")
  end

  desc "Run specs#{desc_suffix} with coverage"
  task "coverage_#{task_suffix}" do
    block.call("COVERAGE" => "1")
  end
end

# Other

desc "Check that model files work when required separately"
task "check_separate_requires" do
  require "rbconfig"
  system({"RACK_ENV" => "test", "LOAD_FILES_SEPARATELY_CHECK" => "1"}, RbConfig.ruby, "-r", "./loader", "-e", "")
end

desc "Run each spec file in a separate process"
task :spec_separate do
  require "rbconfig"

  failures = []
  Dir["spec/**/*_spec.rb"].each do |file|
    failures << file unless system(RbConfig.ruby, "-S", "rspec", file)
  end

  if failures.empty?
    puts "All files passed"
  else
    puts "Failures in:", failures
  end
end

desc "Annotate Sequel models"
task "annotate" do
  ENV["RACK_ENV"] = "development"
  require_relative "loader"
  require_relative "model"
  DB.loggers.clear
  require "sequel/annotate"
  Sequel::Annotate.annotate(Dir["model/**/*.rb"])
end

desc "Emit assets before deploying"
task "assets:precompile" do
  `npm install`
  fail unless $?.success?
  `npm run prod`
  fail unless $?.success?
end

desc "Open a new shell allowing use of by for speeding up tests"
task "by" do
  by_path = "bin/by"

  require "rbconfig"

  by_content = File.binread(Gem.activate_bin_path("by", "by"))
  by_content.sub!(/\A#!.*/, "#!#{RbConfig.ruby} --disable-gems")
  File.binwrite(by_path, by_content)
  ENV["PATH"] = "#{__dir__}/bin:#{ENV["PATH"]}"
  sh("bundle", "exec", "by-session", "./.by-session-setup.rb")
ensure
  File.delete(by_path) if File.file?(by_path)
end

begin
  namespace :linter do
    # "fdr/erb-formatter" can't be required without bundler setup because of custom repository.
    require "bundler/setup"
    Bundler.setup

    require "rubocop/rake_task"
    desc "Run Rubocop"
    RuboCop::RakeTask.new

    desc "Run Brakeman"
    task :brakeman do
      puts "Running Brakeman..."
      require "brakeman"
      Brakeman.run app_path: ".", quiet: true, force_scan: true, print_report: true, run_all_checks: true
    end

    desc "Run ERB::Formatter"
    task :erb_formatter do
      puts "Running ERB::Formatter..."
      require "erb/formatter/command_line"
      files = Dir.glob("views/**/[!icon]*.erb").entries
      ERB::Formatter::CommandLine.new(files + ["--write", "--print-width", "120"]).run
    end

    desc "Validate, lint, format OpenAPI YAML file"
    task :openapi do
      sh "npx redocly lint openapi.yml"
      sh "npx @stoplight/spectral-cli --fail-severity=warn lint openapi.yml"
      sh "echo 'sortPathsBy: path' | npx -- openapi-format -o openapi.yml --sortFile /dev/stdin openapi.yml"
    end
  end

  desc "Run all linters"
  task linter: ["rubocop", "brakeman", "erb_formatter", "openapi"].map { "linter:#{_1}" }
rescue LoadError
  puts "Could not load dev dependencies"
end
