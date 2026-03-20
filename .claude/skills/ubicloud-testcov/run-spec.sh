#!/usr/bin/env bash
# Run rspec with FORCE_AUTOLOAD in the Ubicloud project.
# Usage:
#   .claude/skills/ubicloud-testcov/run-spec.sh                        # all specs
#   .claude/skills/ubicloud-testcov/run-spec.sh spec/lib/foo_spec.rb   # specific file(s)
#   .claude/skills/ubicloud-testcov/run-spec.sh spec/lib/foo_spec.rb:42 # specific line

cd "$(git rev-parse --show-toplevel)"
export FORCE_AUTOLOAD=1
export RACK_ENV=test
exec bundle exec rspec --format documentation "$@"
