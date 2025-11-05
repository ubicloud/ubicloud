# Clover

Clover is the codename for Ubicloud's software. It includes a control
plane, a data plane, and a web console for managing virtual machines
and other applications.

It is a Ruby program that connects to Postgres.

The source code is organized based on the [Roda-Sequel
Stack](https://github.com/jeremyevans/roda-sequel-stack), though
several development choices have been modified. As the name indicates,
this project uses [Roda](https://roda.jeremyevans.net/) (for HTTP
handling) and [Sequel](http://sequel.jeremyevans.net/) (for database
queries).

Web authentication is managed with
[Rodauth](http://rodauth.jeremyevans.net/).

Clover communicates with servers using SSH via the
[net-ssh](https://github.com/net-ssh/net-ssh) library.

Tests are written using [RSpec](https://rspec.info/).

Code is automatically linted and formatted with
[RuboCop](https://rubocop.org/).

The web console is designed with [Tailwind
CSS](https://tailwindcss.com), based on components from [Tailwind
UI](https://tailwindui.com), and uses jQuery for interactivity.

## Development Environment

We recommend using [mise](https://mise.jdx.dev) to manage software
versions. `mise` reads the `.tool-versions` file maintained in the
repository.

For Ruby, obtaining a matching version is especially important because
it is constrained in the [Gemfile](Gemfile).

### Install mise

If you are using `mise`, follow the instructions in the [Getting
Started Manual](https://mise.jdx.dev/getting-started.html). There is a
stand-alone installer, but you may prefer the Homebrew (`brew install
mise`) or Debian/Ubuntu apt repository options, which are also
documented on that page.

After installing `mise`, typing `mise` will display help text:

```sh
$ mise
The front-end to your dev env

Usage: mise [OPTIONS] [TASK] [COMMAND]

Commands:
[...]
```

`mise` has [shell integration instructions in its
manual](https://mise.jdx.dev/installing-mise.html), but included here
are some short shell scripts to guide you through installing it in a
conventional way.

The first task is to integrate `mise` with your shell. The general
idea is to run `mise activate $shell | source` in your shell
initialization file.

You can start a portable shell with `sh` and paste the following to
automatically find the correct file:

```sh
#!/bin/sh

shell=$(basename "$SHELL")
case "$shell" in
  bash) f="$HOME/.bashrc"; [ "$(uname)" = "Darwin" ] && [ -f "$HOME/.bash_profile" ] && [ ! -f "$f" ] && f="$HOME/.bash_profile";;
  zsh)  f="$HOME/.zshrc";;
  fish) f="$HOME/.config/fish/config.fish";;
  *)    echo "Unsupported shell: $shell" >&2; exit 1;;
esac

line="mise activate $shell | source"
mkdir -p "$(dirname "$f")"; touch "$f"
grep -qF "$line" "$f" 2>/dev/null || printf "\n%s\n" "$line" >> "$f"
```

Activating in the shell is enough to proceed. You will need to restart
your shell to apply the changes. After doing so, running `mise doctor`
should report no problems.

For additional convenience, you can optionally install `mise`
autocompletion. The idea is to run `mise completion` in the
appropriate completion directory. This is straightforward for `bash`
and `fish`:

```sh
#!/bin/sh

shell=$(basename "$SHELL")
case "$shell" in
  bash) comp="$HOME/.bash_completion.d/mise";;
  fish) comp="$HOME/.config/fish/completions/mise.fish";;
  *)    echo "Only bash and fish are supported by this script." >&2; exit 1;;
esac

mkdir -p "$(dirname "$comp")"
mise completion "$shell" > "$comp"
echo "Installed mise completions to $comp"
```

`zsh` is more challenging because it has no default completion path in
`$HOME`. The script below sets up a conventional completion directory
in `$HOME`:

```sh
#!/bin/sh

compdir="$HOME/.local/share/zsh/site-functions"
compfile="$compdir/_mise"

mkdir -p "$compdir"
mise completion zsh > "$compfile"

# Add fpath and compinit to .zshrc if not present
zshrc="$HOME/.zshrc"
grep -qF "$compdir" "$zshrc" 2>/dev/null || \
  printf '\nfpath=(%s $fpath)\n' "$compdir" >> "$zshrc"
grep -qF "compinit" "$zshrc" 2>/dev/null || \
  printf '\nautoload -U compinit; compinit\n' >> "$zshrc"

echo "Installed mise zsh completion to $compfile and enabled it in $zshrc"
```

### Decide How to Get Postgres

People have more opinions about how to manage their Postgres version
(e.g., `Postgres.app`, `brew`, `apt install`, etc.), and exact version
matching is less important. If you don't have a preference, we suggest
using `mise` to manage Postgres.

Managing Postgres with mise will increase the number of system
dependencies you need to install to compile it. Instructions on what
to install are provided in the next section.

If you choose to use `mise` to compile and install Postgres, you can
run:

    ln -s mise.local.toml.template mise.local.toml

`mise.local.toml` is a file that `mise` reads and is not committed to
the source. `mise.local.toml.template` *is* committed and updated
occasionally for new Postgres versions, though `mise` does not read
it.

### Installing System Dependencies

`mise` will compile Ruby and/or Postgres. Additionally, some Ruby gems
require compilation. For all of this, you must have a C compiler, a
Rust compiler, and various libraries. [There is documentation listing
the commands you can use for each
platform](https://github.com/rbenv/ruby-build/wiki#suggested-build-environment)
(e.g., Homebrew on macOS, or Ubuntu).

You will also need
[dependencies](https://github.com/mise-plugins/mise-postgres#dependencies)
installed on your system to compile Postgres.

For quick reference, here are some recipes for the most common
platforms we use.

Homebrew:

```sh
xcode-select --install

# Ruby
brew install openssl@3 readline libyaml gmp autoconf

# Postgres
brew install gcc readline zlib curl ossp-uuid icu4c pkg-config
```

Debian/Ubuntu based:

```sh
# Ruby
apt-get install autoconf patch build-essential rustc libssl-dev libyaml-dev libreadline6-dev zlib1g-dev libgmp-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev libdb-dev uuid-dev

# Postgres
apt-get install build-essential libssl-dev libreadline-dev zlib1g-dev libcurl4-openssl-dev uuid-dev icu-devtools libicu-dev
```

### `mise install`

Finally, after installing `mise`, activating it in your shell, and
installing system dependencies, run:

    mise install

This will install all required dependencies. You can then verify that
these dependencies are active:

    $ which ruby
    /home/youruser/.local/share/mise/installs/ruby/3.2.8/bin/ruby
    $ which postgres
    /home/youruser/.local/share/mise/installs/postgres/17.6/bin/postgres
    $ which node
    /home/youruser/.local/share/mise/installs/node/23.6.0/bin/node
    $ which go
    /home/youruser/.local/share/mise/installs/go/1.24.0/bin/go

### Checking `mise`-set Environment Variables

Mise exports additional environment variables besides `$PATH`, and
some of them are useful to know. You can see them in shell format with
`mise env`:

```sh
$ mise env
set -gx GOBIN /home/youruser/.local/share/mise/installs/go/1.24.0/bin
set -gx GOROOT /home/youruser/.local/share/mise/installs/go/1.24.0
set -gx LD_LIBRARY_PATH /home/youruser/.local/share/mise/installs/postgres/17.6/lib
set -gx PATH '/home/youruser/.local/share/mise/installs/ruby/3.2.8/bin:/home/youruser/.local/share/mise/installs/postgres/17.6/bin:/home/youruser/.local/share/mise/installs/node/23.6.0/bin:/home/youruser/.local/share/mise/installs/go/1.24.0/bin:/home/youruser/.local/share/mise/installs/direnv/2.35.0:/home/youruser/.local/share/mise/installs/yq/4.44.2:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin:/snap/bin'
set -gx PGDATA /home/youruser/.local/share/mise/installs/postgres/17.6/data
```

### Installing Postgres

You will need
[dependencies](https://github.com/mise-plugins/mise-postgres) to
compile Postgres installed on your system.

First, set some autoconf `./configure` options to be passed to
Postgres. `.asdf-postgres-configure-options` is not a typo, since
`mise` uses a fork of an `asdf` plugin for this:

```sh
$ echo "POSTGRES_EXTRA_CONFIGURE_OPTIONS='--with-uuid=e2fs --with-openssl'" > ~/.asdf-postgres-configure-options
```

Then run:

```sh
$ mise install postgres
```

There are many alternative ways to get Postgres, e.g. via system
package manager, Homebrew, Postgres.app, etc.  They are all
acceptable, our version requirements for Postgres are more relaxed
than with Ruby.

### Setting up Databases

Clover uses one database per installation, but is developed using two
such installations, and thus, two databases.  One environment is
called "development" and the other "test", and they each have a
database: `clover_development` and `clover_test`.  Only one user is
used to connect to both databases, though, named `clover`.

Presuming you have set up Postgres using `mise`, run a server in a
dedicated terminal window with `postgres -D $PGDATA` set aside, and
then create the user and databases:

```sh
$ createuser -U postgres clover
$ createuser -U postgres clover_password
$ rake setup_database\[development,false\]
$ rake setup_database\[test,false\]
```

The `clover_test` database is used by automated tests, and is prone to
automatic truncation and the like. `clover_development` is the
database used by default, where the developer (you) manages the data.

For example, you might create records in `clover_development`
addressing a few hosts you bought on Hetzner and then experiment with
creating and destroying VMs this way.  Looking at the `clover_test`
database is rare, usually when working on or debugging the testing
infrastructure itself.

### Running migrations

The `setup_database` task will drop databases if they exist, create databases and then migrate them.

If you have already setup the databases, and you want to run new migrations to update them
to the latest schema:

```
$ rake test_up
$ rake dev_up
```

The rake task sets `RACK_ENV` and the `.env.rb` generated by `overwrite_envrb` interprets this to find the right configuration, including the database name to migrate.

### Configuration

You can read [config.rb](config.rb) to see what environment variables
are used.

`CLOVER_DATABASE_URL` and `RACK_ENV` are mandatory, but for running
tests, you will also need to set `CLOVER_SESSION_SECRET` and
`CLOVER_COLUMN_ENCRYPTION_KEY`.  The former is necessary for web (but
not database model) tests, the latter is necessary for any test that
uses an encrypted column.

Our programs load a file `.env.rb` if present to run arbitrary Ruby
code to set up the environment.  You can generate a sensible `.env.rb`
with `rake overwrite_envrb`:

```sh
$ rake overwrite_envrb
$ cat .env.rb
case ENV["RACK_ENV"] ||= "development"
when "test"
  ENV["CLOVER_SESSION_SECRET"] ||= "mbvxopHlcCTWxT6E62weAT+9vxAr1BJp7X3OuQ4K+fFYOLwM20wBVHLuM5tITJDZcEMy2luUD9CDbfgU9okiCw=="
  ENV["CLOVER_DATABASE_URL"] ||= "postgres:///clover_test?user=clover"
  ENV["CLOVER_COLUMN_ENCRYPTION_KEY"] ||= "EWLXd9OzR7Rvs254gVOE9BeTv3fBoZeysOjcNReu5zw="
else
  ENV["CLOVER_SESSION_SECRET"] ||= "/UBMRpwQ5NN3NmSM81FtqDfaaRWhqxbmfFXMxMA2fjcdUk53SZF5n4SKd+uAIpPgPWx1ItRGq/JW1yzQqx0PdQ=="
  ENV["CLOVER_DATABASE_URL"] ||= "postgres:///clover_development?user=clover"
  ENV["CLOVER_COLUMN_ENCRYPTION_KEY"] ||= "9sljUbAiMmH0uiYE6lM64Tix72ehGr0W7yFrbpD+l4s="
end
```

Here we can see that .env.rb chooses the database and keys in question
based on `RACK_ENV`, defaulting to `development`.

Note that these keys change with every execution of `overwrite_envrb`,
so generating a new `.env.rb` can result in encrypted data in your
`clover_development` database being indecipherable.  You are unlikely
to generate this file often, and can probably use the same `.env.rb`
with minor modifications for years.

### Installing Ruby Dependencies a.k.a. Gems

Like most programming environments, Ruby has an application-level
dependency management system, called
[RubyGems](https://rubygems.org/).  We manage those versions through
the program [bundler](https://bundler.io/), which itself we get
through the low-level `gem` command:

```sh
$ which gem
/home/youruser/.local/share/mise/installs/ruby/3.2.8/bin/gem
$ gem install bundler
Fetching bundler-2.6.7.gem
[...]
$ bundle install
Bundle complete! 63 Gemfile dependencies, 178 gems now installed.
[...]
```

Bundler's function is to solve complex gem version constraint upgrades
(when running `bundle update`) and to generate and interpret
[Gemfile.lock](Gemfile.lock) to select the correct Gem versions to be
loaded when multiple versions are installed.  This is done via `bundle
exec` or loading bundler in application code, such as
[loader.rb](loader.rb)'s call to `Bundler.setup`.  In general, `bundle
exec` is necessary when Clover does not control the entry point into
the program, such as `rubocop` (to lint code) or `rspec` (to run
tests):

```sh
$ bundle exec rubocop
```

But it's not necessary with programs in `bin` that we control and load
`loader.rb` right away, as a convenience:

```sh
$ ./bin/pry
```

It's harmless yet duplicative to run:

```sh
$ bundle exec bin/pry
```

### Formatting and Linting code with RuboCop

RuboCop is a code linter and rewriter.  It can take care of all minor
formatting issues automatically, e.g. indentation.  You can run
auto-correction with `bundle exec rubocop -a`

If you ran `overwrite_envrb`, it generates a file that's prone to
correction by RuboCop:

```sh
$ bundle exec rubocop -a
Inspecting 68 files
C...................................................................

Offenses:

.env.rb:6:34: C: [Corrected] Style/StringLiterals: Prefer double-quoted strings unless you need single quotes to avoid extra backslashes for escaping.
    ENV["CLOVER_DATABASE_URL"] ||= 'postgres:///clover_test?user=clover'
                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

68 files inspected, 1 offense detected, 1 offense corrected
```

Some useful corrections are only made with `bundle exec rubocop -A`
(upper case `A`) which applies "unsafe" corrections that may alter the
semantics of the program.

### Running the tests

With the database running and the test database up to date with
migrations, you can run the tests:

```sh
$ bundle exec rspec
```

or even just:

```sh
$ rake
```

As the default rake task runs all the tests.

You can collect coverage by setting:

```sh
$ COVERAGE=1 rake
```

You can run a specific file or line when using `bundle exec rspec`:

```sh
$ bundle exec rspec ./spec/model/strand_spec.rb
$ bundle exec rspec ./spec/model/strand_spec.rb:10
```

There is editor integration for RSpec that are very useful.
`rspec-mode` for emacs (as seen in `M-x list-packages`) has lisp
procedures `rspec-verify` to run `rspec` on the file where the point
is, `rspec-verify-single` to run it on the line the point is at, and
`rspec-rerun` to run `rspec` the same way as whatever came last, which
is excellent when editing code that should affect the outcome of a
test.  There is also `rspec-verify-all` which runs all the specs, but
this is less essential than running one or a few specs with editor
integration.

Assuredly, there is all this and more in other editor environments.

### Running Web Console

Web Console is designed with Tailwind CSS. Tailwind CSS works by scanning
all of your HTML files, JavaScript components, and any other templates
for class names, generating the corresponding styles and then writing
them to a static CSS file. You need to generate CSS file before running
web console if you do not want to see HTML files without any style.

We manage node module versions through [npm](https://www.npmjs.com). It's
installed with `nodejs` package.

```sh
$ which npm
/home/youruser/.local/share/mise/installs/node/23.6.0/bin/npm
$ npm install
[...]
added 46 packages, removed 19 packages, changed 41 packages, and audited 527 packages in 1s

14 packages are looking for funding
    run `npm fund` for details

found 0 vulnerabilities
```

Now we can build CSS file. If you do development on UI, you can run
`npm run watch` on separate terminal window to see changes realtime.

```sh
$ npm run prod
> prod
> npx tailwindcss -o assets/css/app.css --minify

Rebuilding...

Done in 767ms.
```

`assets/css/app.css` should be updated.

After that, start up the web server.

```sh
$ bundle exec rackup
```

And then visiting [http://localhost:9292](http://localhost:9292), you can
create an account. Check the rackup log for the verification link to navigate
to, in production, we would send that output as email. Having verified, log
in. You'll see the "Getting Started" page.

When you change any template file, format them with `erb-formatter`:

```sh
$ rake linter:erb_formatter
```

### Metrics setup

To have the metrics system function during local development, start a
VictoriaMetrics instance in the background with:

```sh
$ victoria-metrics -storageDataPath var/victoria-metrics-data
```

### Cloudifying a Host for Development

We show cloudifying a host from Hetzner, but the principles should work everywhere. Make sure that the Hetzner instance has at least one `One additional subnet /29` ordered and `Ubuntu 24.04 LTS base` is installed.

1. Set the environment variables in `.env.rb`;
    ```ruby
    ENV["HETZNER_USER"] ||= HETZNER_ACCOUNT_ID
    ENV["HETZNER_PASSWORD"] ||= HETZNER_ACCOUNT_PASS
    ENV["HETZNER_SSH_PUBLIC_KEY"] ||= YOUR_PUBLIC_SSH_KEY
    ENV["HETZNER_SSH_PRIVATE_KEY"] ||= YOUR_PRIVATE_SSH_KEY
    ENV["OPERATOR_SSH_PUBLIC_KEYS"] ||= YOUR_PUBLIC_SSH_KEY\nOTHER_PUBLIC_SSH_KEYS
    ```

2. In **terminal 1**, start the respirate process:
    ```sh
    $ ./bin/respirate
    ```

3. In **terminal 2**, connect to REPL console running `./bin/pry` and start cloudification:
    ```ruby
    VM_HOST_IP = ""
    VM_HOST_ID = ""
    default_boot_images = ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]

    st = Prog::Vm::HostNexus.assemble(VM_HOST_IP, provider_name: "hetzner", location_id: Location::HETZNER_FSN1_ID, server_identifier: VM_HOST_ID, default_boot_images: default_boot_images)
    vmh = st.subject
    ```

4. Get back to **terminal 2** and observe `VmHost` cloudification process
    ```ruby
    while true
      lbl = vmh.strand.reload.label
      puts lbl
      break if lbl == "wait"
      sleep 2
    end
    ```

When the `strand` responsible for the VmHost goes to `wait` state, this means the host is ready to be used for Ubicloud services. Now you can use the web console to create resources, such as VMs.

### Conclusion

That's everything there is to know.  As exercise, you can consider
inserting a crash into some source under test (e.g. `strand.rb`) and
try to make the tests fail with a backtrace:

An edited `strand.rb`:
```ruby
[...]
def self.lease(id)
  fail "my first crash"
  affected = DB[<<SQL, id].first
[...]
```

And, the crash:
```sh
$ bundle exec rspec ./spec/model/strand_spec.rb

Randomized with seed 60335

Strand
    can load a prog
    can run a label (FAILED - 1)
    can take leases (FAILED - 2)

Failures:

    1) Strand can run a label
        Failure/Error: st.run

        RuntimeError:
        my first crash
        # ./model/strand.rb:15:in `lease'
        # ./model/strand.rb:9:in `lease'
        # ./model/strand.rb:44:in `run'
        # ./spec/model/strand_spec.rb:24:in `block (2 levels) in <top (required)>'
        # ./spec/spec_helper.rb:41:in `block (3 levels) in <top (required)>'
        # ./spec/spec_helper.rb:40:in `block (2 levels) in <top (required)>'
```
