# Env Statuses
- [ ] Dev
- [ ] Staging
- [ ] Prod

# Backup Info
- **Backup Branch**: `{{BACKUP_BRANCH}}`
- **Upstream Remote**: `ubi` (https://github.com/ubicloud/ubicloud)
- **Date**: `{{DATE}}`

---

# 🤖 Commit Analysis

<details>
<summary><b>Claude's Analysis</b> (click to expand)</summary>

{{COMMIT_ANALYSIS}}

</details>

<details>
<summary><b>📖 Developer Guide</b> (click to expand)</summary>

## Prerequisites
Ensure you have the upstream remote configured:
```bash
git remote add ubi https://github.com/ubicloud/ubicloud
git fetch ubi
```

## Sync Process

### Step 1: Pull Upstream Changes to Main
```bash
# Start from main branch
git checkout main
git pull origin main

# Pull latest changes from upstream
git fetch ubi
git merge ubi/main
# OR: git pull ubi main

# Resolve any conflicts if they occur
# Test the changes if needed

# Push updated main
git push origin main
```

### Step 2: Backup Current Clickhouse Branch (Already Done)
The workflow has already created backup branch: `{{BACKUP_BRANCH}}`

You can verify it exists:
```bash
git fetch origin
git branch -r | grep backup
```

### Step 3: Rebase Clickhouse on New Main
```bash
# Get list of commits that are unique to clickhouse (for reference)
git log --oneline main..clickhouse > /tmp/clickhouse-commits.txt
cat /tmp/clickhouse-commits.txt

# Checkout clickhouse
git checkout clickhouse
git pull origin clickhouse

# Start interactive rebase on new main
git rebase -i main

# During rebase:
# - DROP commits that were upstreamed (see Items section below)
# - SQUASH related commits if needed
# - EDIT commits that need changes due to conflicts
# - Keep commits that are internal-only
```

### Step 4: Handle Rebase Conflicts
When conflicts occur:
```bash
# View conflicting files
git status

# Resolve conflicts in your editor
# After resolving each file:
git add <file>

# Continue rebase
git rebase --continue

# If you need to skip a commit that's no longer relevant:
git rebase --skip

# If things go wrong:
git rebase --abort  # Start over from backup branch
```

### Step 5: Verify the Rebase
```bash
# Check the commit history
git log --oneline main..clickhouse

# Compare with original list
cat /tmp/clickhouse-commits.txt

# Verify internal changes are preserved
git diff main..clickhouse --stat

# Review specific changes if needed
git diff main..clickhouse
```

### Step 6: Push Rebased Clickhouse
```bash
# Force push to update clickhouse branch
# WARNING: This rewrites history
git push origin clickhouse --force-with-lease

# Verify the push succeeded
git log --oneline origin/clickhouse -10
```

### Step 7: Deploy and Test
- [ ] Deploy to Dev environment
- [ ] Run smoke tests
- [ ] Verify internal features still work
- [ ] Deploy to Staging
- [ ] Run full test suite
- [ ] Deploy to Prod
- [ ] Monitor for issues

### Step 8: Handle Backfills (if needed)
If database migrations or backfills are required, document the commands in the Items section below and execute them in the REPL for each environment.

Example backfill flow:
```bash
# In REPL for each environment (Dev -> Staging -> Prod)
# Run backfill commands documented in Items section
```

## Common Issues and Solutions

### Commit Already Upstreamed
If a commit in clickhouse is already merged upstream:
- **Action**: DROP the commit during interactive rebase
- Document in Items section which upstream PR/commit it corresponds to
- Example: "Dropped commit abc123 - upstreamed as https://github.com/ubicloud/ubicloud/pull/XXXX"

### Conflict in Rebase
Determine if the change is still needed:
- **If yes**: Resolve conflict and keep the commit
- **If no** (functionality now in upstream): Drop the commit
- Document the decision in Items section

### New Internal Feature Needs Adjustment
If an internal-only feature conflicts with upstream changes:
- Resolve the conflict to make it compatible with new upstream code
- Test thoroughly to ensure feature still works
- Consider if the change should be upstreamed
- Add to "Commits to upstream" checklist if applicable

### Force Push Failed
If `--force-with-lease` fails:
- Someone else pushed to clickhouse during your rebase
- Fetch and review their changes: `git fetch origin && git log origin/clickhouse`
- Coordinate with team or use `--force` if you're certain

### Backup Branch Needed
If you need to restore from backup:
```bash
# Reset clickhouse to backup branch
git checkout clickhouse
git reset --hard origin/{{BACKUP_BRANCH}}
git push origin clickhouse --force-with-lease
```

</details>

---

# Items
<!-- Document decisions made during sync, including:
- Commits dropped (with upstream PR reference)
- Commits squashed together
- Conflicts and how they were resolved
- Backfill commands that need to be run
- Any manual database changes needed
-->

**Example format:**
- Dropped commit `abc123` - upstreamed as https://github.com/ubicloud/ubicloud/pull/XXXX
- Resolved conflict in `path/to/file.rb` - kept internal implementation because X reason
- Squashed commits `def456` and `ghi789` together
- Backfill needed in all envs: `PostgresServer.all.each { |s| s.update(new_field: value) }`

---

# Commits to upstream
<!-- Checklist of internal commits that should be contributed upstream -->
<!-- WORKFLOW_METADATA: The workflow uses hidden HTML comments below to track items across issues -->
<!-- Unchecked items from previous issues will be automatically added here by the workflow -->

{{PENDING_ITEMS}}
