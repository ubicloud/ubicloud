# frozen_string_literal: true

require "sequel"

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
  case db[<<SQL].single_value
SELECT count(*)
FROM pg_class
WHERE relnamespace = 'public'::regnamespace AND relname = 'account_password_hashes'
SQL
  when 0
    user = db.get(Sequel.lit("current_user"))
    ph_user = "#{user}_password"

    # NB: this grant/revoke cannot be transaction-isolated, so, in
    # sensitive settings, it would be good to check role access.
    db["GRANT CREATE ON SCHEMA public TO ?", ph_user.to_sym].first
    Sequel.postgres(**db.opts.merge(user: ph_user)) do |ph_db|
      ph_db.loggers << Logger.new($stdout) if ph_db.loggers.empty?
      Sequel::Migrator.run(ph_db, "migrate/ph", table: "schema_migrations_password")

      if Config.test?
        # User doesn't have permission to run TRUNCATE on password hash tables, so DatabaseCleaner
        # can't clean Rodauth tables between test runs. While running migrations for test database,
        # we allow it, so cleaner can clean them.
        ph_db["GRANT TRUNCATE ON account_password_hashes TO ?", user.to_sym].first
        ph_db["GRANT TRUNCATE ON account_previous_password_hashes TO ?", user.to_sym].first
      end
    end
    db["REVOKE ALL ON SCHEMA public FROM ?", ph_user.to_sym].first
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
desc "Setup database"
task :setup_database, [:env, :parallel] do |_, args|
  raise "env must be test or dev" if !["test", "development"].include?(args[:env])
  raise "parallel can only be used in test" if args[:parallel] && args[:env] != "test"

  database_count = args[:parallel] ? `nproc`.to_i : 1
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
begin
  require "rspec/core/rake_task"
  ENV["RACK_ENV"] = "test"
  RSpec::Core::RakeTask.new(:spec)
  task default: :spec
rescue LoadError
end

desc "Run specs in parallel using turbo_tests"
task "pspec" do
  # Try to detect number of CPUs on both Linux and Mac
  nproc = `(nproc 2> /dev/null) || sysctl -n hw.logicalcpu`.to_i

  # Limit to 6 processes, as higher number results in more time
  system("bundle", "exec", "turbo_tests", "-n", nproc.clamp(1, 6).to_s)
end

# Other

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
