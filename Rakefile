# Migrate

migrate = lambda do |env, version|
  ENV['RACK_ENV'] = env
  require_relative 'db'
  require 'logger'
  Sequel.extension :migration
  DB.loggers << Logger.new($stdout)
  Sequel::Migrator.apply(DB, 'migrate', version)
end

desc "Migrate test database to latest version"
task :test_up do
  migrate.call('test', nil)
end

desc "Migrate test database all the way down"
task :test_down do
  migrate.call('test', 0)
end

desc "Migrate test database all the way down and then back up"
task :test_bounce do
  migrate.call('test', 0)
  Sequel::Migrator.apply(DB, 'migrate')
end

desc "Migrate development database to latest version"
task :dev_up do
  migrate.call('development', nil)
end

desc "Migrate development database to all the way down"
task :dev_down do
  migrate.call('development', 0)
end

desc "Migrate development database all the way down and then back up"
task :dev_bounce do
  migrate.call('development', 0)
  Sequel::Migrator.apply(DB, 'migrate')
end

desc "Migrate production database to latest version"
task :prod_up do
  migrate.call('production', nil)
end

# Shell

irb = proc do |env|
  ENV['RACK_ENV'] = env
  trap('INT', "IGNORE")
  dir, base = File.split(FileUtils::RUBY)
  cmd = if base.sub!(/\Aruby/, 'irb')
    File.join(dir, base)
  else
    "#{FileUtils::RUBY} -S irb"
  end
  sh "#{cmd} -r ./models"
end

desc "Open irb shell in test mode"
task :test_irb do 
  irb.call('test')
end

desc "Open irb shell in development mode"
task :dev_irb do 
  irb.call('development')
end

desc "Open irb shell in production mode"
task :prod_irb do 
  irb.call('production')
end

# Specs

spec = proc do |pattern|
  sh "#{FileUtils::RUBY} -e 'ARGV.each{|f| require f}' #{pattern}"
end

desc "Run all specs"
task :default => [:model_spec, :web_spec]

desc "Run model specs"
task :model_spec do
  spec.call('./spec/model/*_spec.rb')
end

desc "Run web specs"
task :web_spec do
  spec.call('./spec/web/*_spec.rb')
end

last_line = __LINE__
# Utils

desc "give the application an appropriate name"
task :setup, [:name] do |t, args|
  unless name = args[:name]
    $stderr.puts "ERROR: Must provide a name argument: example: rake setup[AppName]"
    exit(1)
  end

  require 'securerandom'
  File.write('.session_secret', SecureRandom.random_bytes(40))

  lower_name = name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
  File.write('.env.rb', <<END)
ENV['RACK_ENV'] ||= 'development'

ENV['DATABASE_URL'] ||= case ENV['RACK_ENV']
when 'test'
  "postgres:///#{lower_name}_test?user=#{lower_name}"
when 'production'
  "postgres:///#{lower_name}_production?user=#{lower_name}"
else
  "postgres:///#{lower_name}_development?user=#{lower_name}"
end
END

  %w'views/layout.erb routes/prefix1.rb config.ru app.rb spec/web/spec_helper.rb'.each do |f|
    File.write(f, File.read(f).gsub('App', name))
  end

  File.write(__FILE__, File.read(__FILE__).split("\n")[0...(last_line-2)].join("\n") << "\n")
end
