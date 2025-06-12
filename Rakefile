# frozen_string_literal: true

use_auto_parallel_tests = nil
auto_parallel_tests_file = ".auto-parallel-tests"

auto_parallel_tests = lambda do
  if use_auto_parallel_tests.nil?
    use_auto_parallel_tests = File.file?(auto_parallel_tests_file) && File.binread(auto_parallel_tests_file) == "1"
  end

  use_auto_parallel_tests
end

loaded_environment = nil
load_db = lambda do |env|
  raise "cannot load #{env} environment, already loaded #{loaded_environment} environment" if loaded_environment && loaded_environment != env
  loaded_environment = env
  ENV["RACK_ENV"] = env
  require "bundler"
  Bundler.setup(:default, :development)
  require "logger"
  require_relative "db"
end

ncpu = nil
nproc = lambda do
  return ncpu if ncpu
  require "etc"
  # Limit to 10 processes, as higher number results in more time
  ncpu = Etc.nprocessors.clamp(1, 10).to_s
end

clone_test_database = lambda do
  Sequel::DATABASES.each(&:disconnect)
  nproc.call.to_i.times do |i|
    database_name = "clover_test#{i + 1}"
    sh "dropdb --if-exists -U postgres #{database_name}"
    sh "createdb -U postgres -O clover -T clover_test #{database_name}"
  end
end

# Migrate
migrate = lambda do |env, version|
  load_db.call(env)
  Sequel.extension :migration

  DB.extension :pg_enum

  DB.loggers << Logger.new($stdout) if DB.loggers.empty?
  if version.is_a?(String) && File.file?(version)
    Sequel::TimestampMigrator.new(DB, "migrate").run_single(version, :down)
  else
    Sequel::TimestampMigrator.apply(DB, "migrate", version)
  end

  # Check if the alternate-user password hash user needs to run
  # migrations.  It's desirable to avoid always connecting to run
  # migrations, since, almost always, there will be nothing to do and
  # it gluts output.
  case DB[<<SQL].get
SELECT count(*)
FROM pg_class
WHERE relnamespace = 'public'::regnamespace AND relname = 'account_password_hashes'
SQL
  when 0
    user = DB.get(Sequel.lit("current_user"))
    ph_user = "#{user}_password"

    # NB: this grant/revoke cannot be transaction-isolated, so, in
    # sensitive settings, it would be good to check role access.
    DB["GRANT CREATE ON SCHEMA public TO ?", ph_user.to_sym].get
    Sequel.postgres(**DB.opts, user: ph_user) do |ph_db|
      ph_db.loggers << Logger.new($stdout) if ph_db.loggers.empty?
      Sequel::Migrator.run(ph_db, "migrate/ph", table: "schema_migrations_password")
    end
    DB["REVOKE ALL ON SCHEMA public FROM ?", ph_user.to_sym].get
  when 1
    # Already ran the "ph" migration as the alternate user.  This
    # branch is taken nearly all the time in a production situation.
  else
    fail "BUG: account_password_hashes table probing query should return 0 or 1"
  end
end

desc "Migrate test database to latest version"
task test_up: [:_test_up, :refresh_sequel_caches, :annotate]

desc "Migrate test database down. Must specify VERSION environment variable."
task test_down: [:_test_down, :refresh_sequel_caches, :annotate]

# rubocop:disable Rake/Desc
task :_test_up do
  migrate.call("test", nil)
  clone_test_database.call if auto_parallel_tests.call
end

migrate_version = lambda do |env|
  last_irreversible_migration = 20241011
  version = ENV["VERSION"]
  unless version && File.file?(version)
    version = version.to_i
    unless version >= last_irreversible_migration
      raise "Must provide VERSION environment variable >= #{last_irreversible_migration} (or a migration filename) to migrate down"
    end
  end
  migrate.call(env, version)
end

task :_test_down do
  migrate_version.call("test")
  clone_test_database.call if auto_parallel_tests.call
end
# rubocop:enable Rake/Desc

desc "Migrate development database to latest version"
task :dev_up do
  migrate.call("development", nil)
end

desc "Migrate development database down. Must specify VERSION environment variable."
task :dev_down do
  migrate_version.call("development")
end

desc "Migrate production database to latest version"
task :prod_up do
  migrate.call("production", nil)
end

desc "Refresh schema and index caches"
task :refresh_sequel_caches do
  %w[schema index static_cache pg_auto_constraint_validations].each do |type|
    filename = "cache/#{type}.cache"
    File.delete(filename) if File.file?(filename)
  end

  sh({"RACK_ENV" => "test", "FORCE_AUTOLOAD" => "1"}, "bundle", "exec", "ruby", "-r", "./loader", "-e", <<~END)
     DB.dump_schema_cache("cache/schema.cache")
     DB.dump_index_cache("cache/index.cache")
     Sequel::Model.dump_static_cache_cache
     Sequel::Model.dump_pg_auto_constraint_validations_cache
  END
end

# Database setup

desc "Setup database"
task :setup_database, [:env, :parallel] do |_, args|
  raise "env must be test or development" unless ["test", "development"].include?(args[:env])
  parallel = args[:parallel] && args[:parallel] != "false"
  raise "parallel can only be used in test" if parallel && args[:env] != "test"
  File.binwrite(auto_parallel_tests_file, "1") if parallel && !File.file?(auto_parallel_tests_file)

  database_name = "clover_#{args[:env]}"
  sh "dropdb --if-exists -U postgres #{database_name}"
  sh "createdb -U postgres -O clover #{database_name}"
  sh "psql -U postgres -c 'CREATE EXTENSION citext; CREATE EXTENSION btree_gist;' #{database_name}"
  migrate.call(args[:env], nil)
  clone_test_database.call if parallel
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
  sh(env.merge("RUBYOPT" => "-w", "RACK_ENV" => "test", "FORCE_AUTOLOAD" => "1"), "bundle", "exec", "rspec", "spec")
end

turbo_tests = lambda do |env|
  sh(env.merge("RUBYOPT" => "-w", "RACK_ENV" => "test", "FORCE_AUTOLOAD" => "1"), "bundle", "exec", "turbo_tests", "-n", nproc.call)
end

spec = lambda do |env|
  (auto_parallel_tests.call ? turbo_tests : rspec).call(env)
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
    block.call("CLOVER_FREEZE" => "1")
  end
end

coverage_setup = lambda do
  FileUtils.rm_rf("coverage/views")
  FileUtils.mkdir_p("coverage/views")
end

desc "Run specs with coverage"
task "coverage_spec" do
  Rake::Task[auto_parallel_tests.call ? "coverage_pspec" : "coverage_sspec"].invoke
end

desc "Run specs in serial with coverage"
task "coverage_sspec" do
  coverage_setup.call
  rspec.call("COVERAGE" => "1", "RODA_RENDER_COMPILED_METHOD_SUPPORT" => "no")
end

desc "Run specs in parallel with coverage"
task "coverage_pspec" do
  output_file = "coverage/output.txt"
  coverage_setup.call
  command = "bundle exec turbo_tests -n #{nproc.call} 2>&1 | tee #{output_file}"
  sh({"RUBYOPT" => "-w", "RACK_ENV" => "test", "FORCE_AUTOLOAD" => "1", "COVERAGE" => "1", "RODA_RENDER_COMPILED_METHOD_SUPPORT" => "no"}, command)
  command_output = File.binread(output_file)
  unless command_output.include?("Line Coverage: 100.0%") && command_output.include?("Branch Coverage: 100.0%")
    warn "SimpleCov failed with exit 2 due to a coverage related error"
    exit(2)
  end
  exit(1) if command_output.include?("\nFailures:\n")
ensure
  File.delete(output_file) if File.file?(output_file)
end

desc "Run rhizome (data plane) tests"
task "rhizome_spec" do
  sh "COVERAGE=rhizome bundle exec rspec -O /dev/null rhizome"
end

desc "Update cli spec golden files"
task "update_golden_files" do
  sh "mv spec/routes/api/cli/spec-output-files/*.txt spec/routes/api/cli/spec-output-files/.txt spec/routes/api/cli/golden-files/"
end

# Other

desc "Check generated SQL for parameterization"
task "check_query_parameterization" do
  require "rbconfig"
  system({"CHECK_LOGGED_SQL" => "1"}, RbConfig.ruby, "-S", "rake", "frozen_sspec")
  system(RbConfig.ruby, "bin/check_for_parameters", out: "sql_query_parameterization_analysis.txt")
end

desc "Check that model files work when required separately"
task "check_separate_requires" do
  require "rbconfig"
  system({"RACK_ENV" => "test", "LOAD_FILES_SEPARATELY_CHECK" => "1"}, RbConfig.ruby, "-r", "./loader", "-e", "")
end

desc "Run respirate smoke tests"
task :respirate_smoke_test do
  system(RbConfig.ruby, "spec/respirate_smoke_test.rb")
end

desc "Run each spec file in a separate process"
task :spec_separate do
  require "rbconfig"

  failures = []
  Dir["spec/**/*_spec.rb"].each do |file|
    failures << file unless system(RbConfig.ruby, "-w", "-S", "rspec", file)
  end

  if failures.empty?
    puts "All files passed"
  else
    puts "Failures in:", failures
  end
end

cli_version = lambda do
  # Bump version for new releases
  File.read("cli/version.txt").chomp
end

write_cli_makefile = lambda do |filename, version = cli_version.call|
  File.write(filename, "all:\n\tgo build -ldflags '-X main.version=#{version}' -tags osusergo,netgo")
end

desc "Compile cli/ubi binary for current platform"
task "ubi" do
  sh("cd cli && go build -ldflags '-X main.version=#{cli_version.call}' -tags osusergo,netgo")
end

desc "Update ubicloud/cli checkout in ../cli"
task "cli-sync" do
  Dir.chdir("cli") do
    FileUtils.cp(%w[README.md go.mod ubi.go version.txt], "../../cli/")
  end
  FileUtils.cp("LICENSE", "../cli/")
  write_cli_makefile.call("../cli/Makefile")
end

desc "Build release files for cli/ubi"
task "ubi-release" do
  version = cli_version.call

  Dir.chdir("cli") do
    FileUtils.rm_f("ubi")

    os_list = %w[linux windows darwin]
    arch_list = %w[amd64 arm64 386]
    os_list.each do |os|
      arch_list.each do |arch|
        next if os == "darwin" && arch == "386"
        next if os == "windows" && arch == "386" # Windows Defender falsely flags as Trojan:Win32/Bearfoos.A!ml

        filename = "ubi-#{os}-#{arch}-#{version}"
        exe_filename = "ubi#{".exe" if os == "windows"}"

        sh("env GOOS=#{os} GOARCH=#{arch} go build -ldflags '-s -w -X main.version=#{version}' -o #{exe_filename} -tags osusergo,netgo")

        if os == "windows"
          sh("zip", "#{filename}.zip", "ubi.exe")
        else
          sh("tar", "zcf", "#{filename}.tar.gz", "ubi")
        end
        File.delete(exe_filename)
      end
    end

    tarball_dir = "ubi-#{version}"
    Dir.mkdir(tarball_dir)
    sh "cp", "version.txt", "ubi.go", "go.mod", tarball_dir
    write_cli_makefile.call(File.join(tarball_dir, "Makefile"), version)
    FileUtils.rm_f("#{tarball_dir}.tar.gz")
    sh "tar", "zcf", "#{tarball_dir}.tar.gz", tarball_dir
    FileUtils.rm_rf(tarball_dir)
  end
end

desc "Regenerate screenshots for documentation site"
task "screenshots" do
  sh("bundle", "exec", "ruby", "bin/regen-screenshots")
end

desc "Annotate Sequel models"
task "annotate" do
  load_db.call("test")
  require_relative "loader"
  require_relative "model"
  DB.loggers.clear
  require "sequel/annotate"
  Sequel::Annotate.annotate(Dir["model/**/*.rb"])
end

desc "Build sdk gem"
task "build-sdk-gem" do
  sh("cd sdk/ruby && gem build ubicloud.gemspec")
end

desc "Emit assets before deploying"
task "assets:precompile" do
  begin
    sh("npm", "install")
  rescue
    puts "npm install failed, falling back to registry.npmmirror.com..."
    sh("npm", "install", "--registry=https://registry.npmmirror.com")
  end
  sh("npm", "run", "prod")
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

namespace :linter do
  desc "Run Rubocop"
  task :rubocop do
    sh "BUNDLE_WITH=rubocop bundle exec rubocop"
  end

  desc "Run Brakeman"
  task :brakeman do
    require "bundler"
    Bundler.setup(:lint)
    puts "Running Brakeman..."
    require "brakeman"
    Brakeman.run app_path: ".", quiet: true, force_scan: true, print_report: true, run_all_checks: true
  end

  desc "Run ERB::Formatter"
  task :erb_formatter do
    # "fdr/erb-formatter" can't be required without bundler setup because of custom repository.
    require "bundler"
    Bundler.setup(:lint)
    puts "Running ERB::Formatter..."
    require "erb/formatter/command_line"
    files = Dir.glob("views/**/[!icon]*.erb").entries
    files.delete("views/components/form/select.erb")
    files.delete("views/github/runner.erb")
    ERB::Formatter::CommandLine.new(files + ["--write", "--print-width", "120"]).run
  end

  desc "Run golangci-lint"
  task :go do
    sh "golangci-lint run cli/ubi.go"
  end

  desc "Validate, lint, format OpenAPI YAML file"
  task :openapi do
    sh "npx redocly lint openapi/openapi.yml --config openapi/redocly.yml"
    sh "npx @stoplight/spectral-cli lint openapi/openapi.yml --fail-severity=warn --ruleset openapi/.spectral.yml"
    sh "npx openapi-format openapi/openapi.yml --configFile openapi/openapi_format.yml"
  end
end

desc "Run all linters"
task linter: ["rubocop", "brakeman", "erb_formatter", "openapi", "go"].map { "linter:#{it}" }
