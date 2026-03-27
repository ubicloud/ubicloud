# Claude Code Guidelines for Ubicloud

## Command Strategy

Prioritize existing skills and scripts before reaching for ad-hoc commands:
 
1. **Check existing skills and scripts first** — `/.claude/skills/` and `.devcontainer/scripts/` cover most common operations (provisioning, waiting for state, SSH, API calls). Use them.
2. **If not covered** — prefer a systematic solution over a one-off approval:
   - Create a reusable script under `.devcontainer/scripts/` or `.claude/skills/`
   - Propose a focused allowlist entry in `settings.json` that covers a clear category (e.g. `"Bash(tail *)"`)

## Bash Command Permissions

- **Never use `sed` for any purpose.** Use the built-in Edit/MultiEdit tools for file modifications. For text transformation in pipelines, 
  use `awk '{print ...}'` or python one-liners like 
  `python3 -c "import sys; ..."`.
- **Never use in-place file modification via shell commands.** 
  No `sed -i`, no `perl -pi -e`, no `ed`. Always use Edit/MultiEdit.
- For read-only text extraction from command output, prefer: 
  `grep`, `head`, `tail`, `cut`, `wc`, `awk` (print only, no system()).
- For complex text processing, write a small Python script rather 
  than a long shell pipeline.
- **Avoid broad permissions** like `bash -c *` — these defeat the purpose of the allowlist. Invest in skills instead.
- **Avoid command with security risks** Avoid `#-` prefixed comment lines or other inline narration in code.
- **Never prefix commands with `RACK_ENV=...`** — `RACK_ENV=development` is set in .env.rb by default. Adding it inline produces a command starting with `RACK_ENV=...` which won't match the permission patterns, causing an approval prompt. Rake test tasks (`rake coverage`, `rake spec`, etc.) and `run-spec.sh` set `RACK_ENV=test` internally — no manual override needed.
- **Pipes break pattern matching** — `bundle exec ruby -e "..." | head -5` won't match `"Bash(bundle exec ruby*)"`. Keep output handling inside the Ruby script instead of piping externally.
- **Prefer in-script output control** — use `puts`, `.first(N)`, or `.take(N)` inside Ruby rather than `| head` or `| grep`.
- **Avoid `2>/dev/null | ...`** — combine stderr suppression and piping inside the script when possible.
- **No `#` comments inside `-e` strings** — a quoted newline followed by a `#`-prefixed line in a `bundle exec ruby -e "..."` command is flagged as potentially hiding arguments from line-based permission checks. Keep all comments outside the string or omit them.

### When Running Inside Devcontainer

- Foreman manages `respirate.1` (strand runner) and `monitor.1`. Logs at `/var/log/foreman/foreman.log`.
- Restart foreman after fixing orphaned records to resume strand processing.

## Multi-Agent Teams

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is enabled in `settings.json`. Use `TeamCreate`, `TaskCreate`, `SendMessage` to spin up parallel investigation agents (e.g., one for control plane analysis, one for VM SSH inspection).
