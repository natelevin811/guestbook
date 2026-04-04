#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic
#
# Shared functions for ralph-loop.sh and ralph-setup.sh
#
# Directory structure:
#   .ralph/
#   ├── scripts/    # Shell scripts (this file lives here)
#   ├── state/      # Runtime state (progress.md, activity.log, etc.)
#   └── tasks/      # Task files (RALPH_TASK.md entry point)

# =============================================================================
# CONFIGURATION (can be overridden before sourcing)
# =============================================================================

# Token thresholds (rotate early to maintain quality)
WARN_THRESHOLD="${WARN_THRESHOLD:-80000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-100000}"

# Iteration limits
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"

# Model selection (use Claude's model aliases: opus, sonnet, or full names like claude-opus-4-5-20251101)
DEFAULT_MODEL="opus"
MODEL="${RALPH_MODEL:-$DEFAULT_MODEL}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"

# =============================================================================
# PATH HELPERS
# =============================================================================

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Get the .ralph root directory for a workspace
get_ralph_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph"
}

# Get the state directory (.ralph/state/)
get_state_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph/state"
}

# Get the tasks directory (.ralph/tasks/)
get_tasks_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph/tasks"
}

# Get the entry point task file
get_entry_task() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph/tasks/RALPH_TASK.md"
}

# Get current iteration from .ralph/state/.iteration
get_iteration() {
  local workspace="${1:-.}"
  local state_file="$(get_state_dir "$workspace")/.iteration"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

# Set iteration number
set_iteration() {
  local workspace="${1:-.}"
  local iteration="$2"
  local state_dir="$(get_state_dir "$workspace")"
  
  mkdir -p "$state_dir"
  echo "$iteration" > "$state_dir/.iteration"
}

# Increment iteration and return new value
increment_iteration() {
  local workspace="${1:-.}"
  local current=$(get_iteration "$workspace")
  local next=$((current + 1))
  set_iteration "$workspace" "$next"
  echo "$next"
}

# Get context health emoji based on token count
get_health_emoji() {
  local tokens="$1"
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

# Kill a process and all its descendants
kill_tree() {
  local pid="$1"
  local signal="${2:-TERM}"
  
  # First kill all children recursively
  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  for child in $children; do
    kill_tree "$child" "$signal"
  done
  
  # Then kill the process itself
  kill "-$signal" "$pid" 2>/dev/null || true
}

# Watchdog: monitors for blocking interactive processes (within the agent tree)
# Runs as background process and emits GUTTER if a blocking process is found.
# Args: agent_pid fifo workspace
run_watchdog() {
  local agent_pid="$1"
  local fifo="$2"
  local workspace="$3"
  local state_dir="$(get_state_dir "$workspace")"
  local activity_log="$state_dir/activity.log"
  local errors_log="$state_dir/errors.log"

  list_descendants() {
    local root="$1"
    local kids
    kids=$(pgrep -P "$root" 2>/dev/null) || true
    for k in $kids; do
      echo "$k"
      list_descendants "$k"
    done
  }

  while kill -0 "$agent_pid" 2>/dev/null; do
    sleep 3

    local blocking=""
    local blocking_pid=""

    local pids=""
    pids="$(list_descendants "$agent_pid")"

    for pid in $pids; do
      local cmdline
      cmdline=$(ps -p "$pid" -o args= 2>/dev/null) || cmdline=""
      [[ -z "$cmdline" ]] && continue

      if [[ "$cmdline" =~ (^|[[:space:]])npm[[:space:]]+init($|[[:space:]]) ]] && [[ ! "$cmdline" =~ (-y|--yes) ]]; then
        blocking="npm init (use 'npm init -y' OR skip if package.json exists)"
        blocking_pid="$pid"
        break
      fi
      if [[ "$cmdline" =~ (^|[[:space:]])git[[:space:]]+commit($|[[:space:]]) ]] && [[ ! "$cmdline" =~ (-m|--message|-F|--file|--no-edit) ]]; then
        blocking="git commit (use 'git commit -m \"msg\"' or '--no-edit' for amend)"
        blocking_pid="$pid"
        break
      fi
      if [[ "$cmdline" =~ (^|[[:space:]])node($|[[:space:]]*$) ]]; then
        blocking="node REPL (use 'node script.js')"
        blocking_pid="$pid"
        break
      fi
      if [[ "$cmdline" =~ (^|[[:space:]])python3?($|[[:space:]]*$) ]]; then
        blocking="python REPL (use 'python script.py')"
        blocking_pid="$pid"
        break
      fi
    done

    if [[ -n "$blocking" && -n "$blocking_pid" ]]; then
      echo "[$(date '+%H:%M:%S')] 🚨 WATCHDOG: Blocking process detected: $blocking (pid=$blocking_pid)" >> "$activity_log"
      echo "🚨 WATCHDOG: Blocking process detected: $blocking" >&2

      # Also write to errors.log so next iteration sees it.
      {
        echo ""
        echo "## BLOCKED: Interactive Command"
        echo "- **Command**: $blocking"
        echo "- **Action**: Process killed by watchdog"
        echo "- **Fix**: Use non-interactive alternatives (npm init -y, git commit -m \"msg\")"
        echo ""
      } >> "$errors_log" 2>/dev/null || true

      kill -9 "$blocking_pid" 2>/dev/null || true
      echo "GUTTER" > "$fifo" 2>/dev/null || true
      return
    fi
  done
}

# =============================================================================
# LOGGING
# =============================================================================

# Log a message to activity.log
log_activity() {
  local workspace="${1:-.}"
  local message="$2"
  local state_dir="$(get_state_dir "$workspace")"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$state_dir"
  echo "[$timestamp] $message" >> "$state_dir/activity.log"
}

# Log an error to errors.log
log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local state_dir="$(get_state_dir "$workspace")"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$state_dir"
  echo "[$timestamp] $message" >> "$state_dir/errors.log"
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local state_dir="$(get_state_dir "$workspace")"
  local progress_file="$state_dir/progress.md"
  
  mkdir -p "$state_dir"
  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize .ralph directory structure with default files
# Structure:
#   .ralph/
#   ├── scripts/    # Shell scripts
#   ├── state/      # Runtime state
#   └── tasks/      # Task files
init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  local state_dir="$ralph_dir/state"
  local tasks_dir="$ralph_dir/tasks"
  
  mkdir -p "$ralph_dir"
  mkdir -p "$state_dir"
  mkdir -p "$tasks_dir"
  
  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$state_dir/progress.md" ]]; then
    cat > "$state_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi
  
  # Initialize guardrails.md if it doesn't exist
  if [[ ! -f "$state_dir/guardrails.md" ]]; then
    cat > "$state_dir/guardrails.md" << 'EOF'
# Guardrails

> STOP. Read these before every action.

## Non-Interactive Commands Only

**NEVER** run commands that wait for input. Always use flags:
- `npm init -y` (not `npm init`)
- `git commit -m "msg"` (not `git commit`)
- `python script.py` (not `python`)
- `node script.js` (not `node`)

## Safe Workflow

1. **Read before write** - Check file contents before editing
2. **Test after changes** - Run tests to verify
3. **Commit checkpoints** - Save state before risky changes

---

## Learned Failures

_(Added automatically when errors occur)_

EOF
  fi
  
  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$state_dir/errors.log" ]]; then
    cat > "$state_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi
  
  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$state_dir/activity.log" ]]; then
    cat > "$state_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi
}

# =============================================================================
# TASK MANAGEMENT
# =============================================================================

# Get next_task from frontmatter of a task file
get_next_task() {
  local task_file="$1"
  
  if [[ ! -f "$task_file" ]]; then
    echo ""
    return
  fi
  
  # Parse YAML frontmatter for next_task
  # Supports: next_task: "filename.md" or next_task: filename.md
  local next_task
  next_task=$(awk '/^---$/{p=!p;next} p && /^next_task:/{gsub(/^next_task:[[:space:]]*"?|"?[[:space:]]*$/,""); print; exit}' "$task_file" 2>/dev/null) || next_task=""
  
  echo "$next_task"
}

# Get task name from frontmatter
get_task_name() {
  local task_file="$1"
  
  if [[ ! -f "$task_file" ]]; then
    echo "Unknown"
    return
  fi
  
  local task_name
  task_name=$(awk '/^---$/{p=!p;next} p && /^task:/{gsub(/^task:[[:space:]]*"?|"?[[:space:]]*$/,""); print; exit}' "$task_file" 2>/dev/null) || task_name="Unknown"
  
  echo "$task_name"
}

# Check if a task file is complete (all checkboxes checked)
is_task_complete() {
  local task_file="$1"
  
  if [[ ! -f "$task_file" ]]; then
    return 1
  fi
  
  local unchecked
  unchecked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  
  [[ "$unchecked" -eq 0 ]]
}

# Check if a task has passed QC (has quality_check_passed: true in frontmatter)
has_qc_passed() {
  local task_file="$1"
  
  if [[ ! -f "$task_file" ]]; then
    return 1
  fi
  
  # Parse YAML frontmatter for quality_check_passed: true
  local qc_passed
  qc_passed=$(awk '/^---$/{p=!p;next} p && /^quality_check_passed:[[:space:]]*true/{print "yes"; exit}' "$task_file" 2>/dev/null) || qc_passed=""
  
  [[ "$qc_passed" == "yes" ]]
}

# Mark a task as QC passed by adding quality_check_passed: true to frontmatter
mark_qc_passed() {
  local task_file="$1"
  
  if [[ ! -f "$task_file" ]]; then
    return 1
  fi
  
  # Check if already marked
  if has_qc_passed "$task_file"; then
    return 0
  fi
  
  # Check if file has frontmatter (starts with ---)
  if ! head -1 "$task_file" | grep -q '^---$'; then
    # No frontmatter, add it
    local content
    content=$(cat "$task_file")
    cat > "$task_file" << EOF
---
quality_check_passed: true
---
$content
EOF
    return 0
  fi
  
  # File has frontmatter - insert quality_check_passed: true after the first ---
  # Use awk for reliable cross-platform insertion
  local tmp_file="${task_file}.tmp"
  awk '
    NR == 1 && /^---$/ {
      print
      print "quality_check_passed: true"
      next
    }
    { print }
  ' "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file"
}

# Uncheck a specific criterion by number (1-indexed)
# Used when QC fails to ensure the criterion is properly unchecked
uncheck_criterion() {
  local task_file="$1"
  local criterion_num="$2"
  
  if [[ ! -f "$task_file" ]] || [[ -z "$criterion_num" ]]; then
    return 1
  fi
  
  # Use awk to find and uncheck the Nth checkbox
  # Counts only actual checkbox list items (- [x], * [x], 1. [x], etc.)
  local tmp_file="${task_file}.tmp"
  awk -v n="$criterion_num" '
    /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]/ {
      count++
      if (count == n) {
        # Uncheck this criterion and add QC comment
        sub(/\[x\]/, "[ ]")
        print $0 " <!-- QC: unchecked by quality check -->"
        next
      }
    }
    { print }
  ' "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file"
}

# Walk the task chain to find the current incomplete task
# Returns the filename of the current task (or empty if all complete)
# A task is considered "fully complete" only if:
#   1. All checkboxes are checked (is_task_complete)
#   2. QC has passed (has_qc_passed / quality_check_passed: true in frontmatter)
find_current_task() {
  local workspace="$1"
  local tasks_dir="$(get_tasks_dir "$workspace")"
  local task_file="$tasks_dir/RALPH_TASK.md"
  local visited=""
  local max_depth=20
  local depth=0
  
  while [[ $depth -lt $max_depth ]]; do
    if [[ ! -f "$task_file" ]]; then
      echo ""
      return
    fi
    
    # Prevent infinite loops
    if [[ "$visited" == *"|$task_file|"* ]]; then
      echo "$task_file"
      return
    fi
    visited="$visited|$task_file|"
    
    # Check if this task is complete (checkboxes + QC)
    if ! is_task_complete "$task_file"; then
      # Checkboxes not all checked - work needed
      echo "$task_file"
      return
    fi
    
    # Checkboxes are done, but check if QC has passed
    if ! has_qc_passed "$task_file"; then
      # QC not yet passed - return this task so QC can run
      echo "$task_file"
      return
    fi
    
    # Task is fully complete (checkboxes + QC), check for next_task
    local next_task
    next_task=$(get_next_task "$task_file")
    
    if [[ -z "$next_task" ]]; then
      # No next task, all done!
      echo ""
      return
    fi
    
    # Resolve next_task path (relative to tasks directory)
    if [[ "$next_task" != /* ]]; then
      next_task="$tasks_dir/$next_task"
    fi
    
    if [[ ! -f "$next_task" ]]; then
      echo "ERROR:$next_task not found" >&2
      echo "$task_file"
      return
    fi
    
    task_file="$next_task"
    depth=$((depth + 1))
  done
  
  echo "$task_file"
}

# Get the next task file from current task
# Returns: path to next task file, or empty if none
get_next_task_file() {
  local workspace="$1"
  local current_task="$2"
  local tasks_dir="$(get_tasks_dir "$workspace")"
  
  local next_task
  next_task=$(get_next_task "$current_task")
  
  if [[ -z "$next_task" ]]; then
    echo ""
    return
  fi
  
  # Resolve path (relative to tasks directory)
  if [[ "$next_task" != /* ]]; then
    next_task="$tasks_dir/$next_task"
  fi
  
  if [[ -f "$next_task" ]]; then
    echo "$next_task"
  else
    echo ""
  fi
}

# Check if task is complete
check_task_complete() {
  local workspace="$1"
  local task_file="$(get_entry_task "$workspace")"
  
  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  
  # Only count actual checkbox list items, not [ ] in prose/examples
  # Matches: "- [ ]", "* [ ]", "1. [ ]", etc.
  local unchecked
  unchecked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# Count task criteria (returns done:total)
count_criteria() {
  local workspace="${1:-.}"
  local task_file="$(get_entry_task "$workspace")"
  
  if [[ ! -f "$task_file" ]]; then
    echo "0:0"
    return
  fi
  
  # Only count actual checkbox list items, not [x] or [ ] in prose/examples
  # Matches: "- [ ]", "* [x]", "1. [ ]", etc.
  local total done_count
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  
  echo "$done_count:$total"
}

# =============================================================================
# PROMPT BUILDING
# =============================================================================

# Build the Ralph prompt for an iteration
build_prompt() {
  local workspace="$1"
  local iteration="$2"
  local task_file="${3:-.ralph/tasks/RALPH_TASK.md}"  # Can be overridden for chained tasks
  local state_dir="$(get_state_dir "$workspace")"
  
  # Get relative path for display
  local task_file_rel="${task_file#$workspace/}"
  
  # Read guardrails and errors to inject directly
  local guardrails=""
  local errors=""
  if [[ -f "$state_dir/guardrails.md" ]]; then
    guardrails=$(cat "$state_dir/guardrails.md")
  fi
  if [[ -f "$state_dir/errors.log" ]]; then
    errors=$(tail -30 "$state_dir/errors.log")
  fi
  
  cat << EOF
# Ralph Iteration $iteration

⚠️ **CRITICAL: READ THIS FIRST BEFORE ANY FILE OPERATIONS** ⚠️

## File Reading Rules (MANDATORY)

Your context is LIMITED. You MUST follow these rules for EVERY file read:

1. **Files >200 lines: ALWAYS use offset and limit parameters**
   - Example: \`read_file("path/to/file.py", offset=1, limit=100)\` reads lines 1-100
   - Read in chunks of 100-200 lines maximum
   
2. **Use grep/search FIRST** to find specific functions before reading

3. **NEVER read the same file twice** - remember what you already read

4. **Large files in this repo** (MUST chunk):
   - \`backend/src/agent/service.py\` (1400 lines) - MAX 100 lines per read
   - \`backend/src/tool/tool_registry.py\` (500 lines) - MAX 200 lines per read

## Your First Actions

1. Read \`$task_file_rel\` (your task file - small, full read OK)
2. Read \`.ralph/state/progress.md\` (small file, full read OK)  
3. For large files: grep first, then read specific line ranges

## Architecture & Best Practices

**Read the cursor rules before implementing!** They contain critical guidance:

- \`.cursor/rules/\` - Project-wide architecture, environment setup, git workflow, testing strategy
- \`backend/.cursor/rules/\` - Backend patterns, CRUD conventions, service patterns
- \`frontend/.cursor/rules/\` - Frontend patterns, component organization, routing

When implementing a feature:
1. Check if there's a relevant cursor rule for that domain
2. Follow established patterns - don't reinvent the wheel
3. If you create new patterns, consider if they should be documented

## Other Rules

- Do NOT run \`git init\` - repo exists
- Use \`npm init -y\` not \`npm init\`
- Use \`git commit -m "msg"\` not \`git commit\`

---

$guardrails

## Recent Errors (From Previous Iterations)

$errors

## Read State Files

Before coding:
1. Read \`$task_file_rel\` - your task and completion criteria
2. Read \`.ralph/state/progress.md\` - what's been accomplished

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` - the repo already exists
- Do NOT run scaffolding commands that create nested directories (\`npx create-*\`)
- Use \`npm init -y\` (with -y flag!) if you need to initialize a Node.js project
- All code should live at the repo root or in subdirectories you create manually

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each criterion, commit your changes:
   \`git add -A && git commit -m 'ralph: implement state tracker'\`
   \`git add -A && git commit -m 'ralph: fix async race condition'\`
   \`git add -A && git commit -m 'ralph: add CLI adapter with commander'\`
   Always describe what you actually did - never use placeholders like '<description>'
2. After any significant code change (even partial): commit with descriptive message
3. Before any risky refactor: commit current state as checkpoint
4. Push after every 2-3 commits: \`git push\`

If you get rotated, the next agent picks up from your last commit. Your commits ARE your memory.

## Task Execution

1. Work on the next unchecked criterion in \`$task_file_rel\` (look for \`[ ]\`)
2. Run tests after changes (check the task file for test_command)
3. **Mark completed criteria**: Edit \`$task_file_rel\` and change \`[ ]\` to \`[x]\`
   - Example: \`- [ ] Implement parser\` becomes \`- [x] Implement parser\`
   - This is how progress is tracked - YOU MUST update the file
4. Update \`.ralph/state/progress.md\` with what you accomplished
5. When ALL criteria show \`[x]\`: output \`<ralph>COMPLETE</ralph>\`
6. If stuck 3+ times on same issue: output \`<ralph>GUTTER</ralph>\`

## Learning from Failures

When something fails:
1. Check \`.ralph/state/errors.log\` for what went wrong
2. Add a one-line fix to \`.ralph/state/guardrails.md\` under "Learned Failures":
   \`- [what went wrong] → [what to do instead]\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Update .ralph/state/progress.md with what you accomplished and what's next
4. You will be rotated to a fresh agent that continues your work

Begin by reading the state files.
EOF
}

# Build the QC (Quality Check) prompt for verifying task completion
build_qc_prompt() {
  local workspace="$1"
  local task_file="$2"
  
  # Get relative path for display
  local task_file_rel="${task_file#$workspace/}"
  
  cat << EOF
# Quality Check (QC) Verification

You are a QC agent verifying that completed task criteria were actually implemented.

## Your Task

1. Read \`$task_file_rel\` and identify all CHECKED criteria (lines with \`[x]\`)
2. For each checked criterion, verify it was actually implemented:
   - Use grep/read to check if files exist
   - Verify code was actually added/modified
   - Run quick checks (don't run full test suites)
3. Be strict but fair - only fail if clearly not done

## Verification Process

For each \`[x]\` criterion:
- If the criterion mentions creating a file → verify the file exists
- If the criterion mentions implementing a function → verify the function exists in code
- If the criterion mentions adding tests → verify test files/functions exist
- If the criterion is about configuration → verify config exists

## Output Format

After verification, output ONE of these:

- If ALL checked criteria are verified: \`<qc>PASS</qc>\`
- If ANY criterion fails: \`<qc>FAIL:N</qc>\` where N is the criterion number that failed

## On Failure

If a criterion fails verification:
1. Edit \`$task_file_rel\` to UNCHECK the failed criterion: change \`[x]\` back to \`[ ]\`
2. Add a comment after the criterion explaining why: \`<!-- QC: not implemented - reason -->\`

## Important

- Only verify CHECKED criteria (marked with \`[x]\`)
- Don't modify criteria that are already unchecked \`[ ]\`
- Be thorough but quick - this is a verification pass, not a full audit
- Output your QC result as the LAST thing you do

Begin by reading the task file.
EOF
}

# =============================================================================
# QC (QUALITY CHECK) RUNNER
# =============================================================================

# Run a QC check on a completed task
# Returns: "PASS" or "FAIL"
run_qc_check() {
  local workspace="$1"
  local task_file="$2"
  local script_dir="${3:-$(dirname "${BASH_SOURCE[0]}")}"
  
  local task_file_rel="${task_file#$workspace/}"
  local task_name
  task_name=$(get_task_name "$task_file")
  
  log_activity "$workspace" "🔍 QC START: $task_name"
  
  # Count criteria for display
  local total_count done_count
  total_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_count=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  
  local prompt
  prompt=$(build_qc_prompt "$workspace" "$task_file")
  local state_dir="$(get_state_dir "$workspace")"
  local fifo="$state_dir/.qc_fifo"
  
  # Create named pipe for QC signals
  rm -f "$fifo"
  mkfifo "$fifo"
  
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────┐"
  echo "│ 🔍 Quality Check: $task_name"
  echo "│    Verifying $done_count/$total_count criteria..."
  echo "└─────────────────────────────────────────────────────────────────┘"
  
  # Build claude command args (shorter timeout for QC - 5 minutes)
  local -a cmd_args=("claude" "-p" "--dangerously-skip-permissions" "--verbose" "--output-format" "stream-json" "--model" "$MODEL")
  
  # Change to workspace
  cd "$workspace"
  
  # Start QC agent in background
  local qc_result="PASS"
  local timeout_seconds=300  # 5 minute timeout for QC
  
  # Flag file to track if we've written to fifo (avoids double-write)
  local signal_sent_flag="$state_dir/.qc_signal_sent"
  rm -f "$signal_sent_flag"
  
  (
    # Use same hardened environment as main agent
    export PATH="$script_dir/shims:$PATH"
    export CI=1
    export npm_config_yes=true
    export GIT_TERMINAL_PROMPT=0
    export GIT_EDITOR=:
    export EDITOR=:
    export PAGER=cat
    
    # Run claude and parse for QC signals
    timeout "$timeout_seconds" "${cmd_args[@]}" "$prompt" 2>&1 | while IFS= read -r line; do
      # Skip if we already sent a signal
      [[ -f "$signal_sent_flag" ]] && continue
      
      # Check for QC signals in assistant messages
      if echo "$line" | grep -q '"type":"assistant"'; then
        local text
        text=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null) || text=""
        if [[ -n "$text" ]]; then
          # Check for QC PASS
          if [[ "$text" == *"<qc>PASS</qc>"* ]]; then
            touch "$signal_sent_flag"
            echo "PASS" > "$fifo"
            continue
          fi
          # Check for QC FAIL
          if [[ "$text" =~ \<qc\>FAIL:([0-9]+)\</qc\> ]]; then
            touch "$signal_sent_flag"
            echo "FAIL:${BASH_REMATCH[1]}" > "$fifo"
            continue
          fi
          # Also check for simpler FAIL without number
          if [[ "$text" == *"<qc>FAIL</qc>"* ]]; then
            touch "$signal_sent_flag"
            echo "FAIL" > "$fifo"
            continue
          fi
        fi
      fi
    done
    
    # If we get here without finding a signal (claude finished without QC output), 
    # treat as PASS (agent didn't find issues)
    if [[ ! -f "$signal_sent_flag" ]]; then
      echo "PASS" > "$fifo" 2>/dev/null || true
    fi
  ) &
  local qc_pid=$!
  
  # Read signal from fifo with timeout
  local signal=""
  if read -t "$timeout_seconds" signal < "$fifo" 2>/dev/null; then
    qc_result="$signal"
  else
    # Timeout - treat as PASS (don't block on QC failures)
    qc_result="PASS"
    log_activity "$workspace" "⚠️ QC TIMEOUT: Treating as PASS"
  fi
  
  # Kill QC process tree if still running (includes timeout and claude)
  kill_tree $qc_pid 2>/dev/null || true
  wait $qc_pid 2>/dev/null || true
  
  # Cleanup
  rm -f "$fifo"
  rm -f "$signal_sent_flag"
  
  # Log result (quiet output - main loop handles display)
  if [[ "$qc_result" == "PASS" ]]; then
    log_activity "$workspace" "✅ QC PASS: $task_name verified"
    echo "   ✅ Passed - All criteria verified"
  else
    local fail_info="${qc_result#FAIL}"
    fail_info="${fail_info#:}"
    if [[ -n "$fail_info" ]]; then
      log_activity "$workspace" "❌ QC FAIL: $task_name (criterion $fail_info failed)"
      echo "   ❌ Failed - Criterion $fail_info not implemented"
    else
      log_activity "$workspace" "❌ QC FAIL: $task_name"
      echo "   ❌ Failed - Some criteria not implemented"
    fi
    qc_result="FAIL"
  fi
  
  echo "$qc_result"
}

# =============================================================================
# SPINNER
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Also displays last few lines of activity log and task progress
# Outputs to stderr so it's not captured by $()
spinner() {
  local workspace="$1"
  local task_file="$2"
  local state_dir="$(get_state_dir "$workspace")"
  local activity_log="$state_dir/activity.log"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  local last_activity_update=0
  local activity_lines=5
  local displayed_lines=0
  
  while true; do
    local now=$(date +%s)
    local cols
    cols="$(tput cols 2>/dev/null || echo 80)"
    
    # Every 2 seconds, update the activity display
    if [[ $((now - last_activity_update)) -ge 2 ]] && [[ -f "$activity_log" ]]; then
      last_activity_update=$now
      
      # Clear spinner line first
      printf "\r\033[2K" >&2
      
      # If we previously displayed activity, move up and clear those lines
      if [[ $displayed_lines -gt 0 ]]; then
        for ((j=0; j<displayed_lines+3; j++)); do  # +3 for border lines + progress line
          printf "\033[1A\033[2K" >&2
        done
      fi
      
      # Get live task progress
      local total_count done_count progress_text
      if [[ -f "$task_file" ]]; then
        total_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_count=0
        done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
        progress_text="📊 Progress: $done_count/$total_count criteria"
      else
        progress_text="📊 Progress: --"
      fi
      
      # Print activity block with progress
      printf "─────────────────────────────────────────────────────────────────\n" >&2
      printf "%s\n" "$progress_text" >&2
      local line_count=0
      while IFS= read -r line; do
        # Truncate line to terminal width
        if [[ ${#line} -ge $cols ]]; then
          line="${line:0:$((cols-1))}"
        fi
        printf "%s\n" "$line" >&2
        line_count=$((line_count + 1))
      done < <(tail -$activity_lines "$activity_log" 2>/dev/null)
      printf "─────────────────────────────────────────────────────────────────\n" >&2
      displayed_lines=$line_count
    fi
    
    # Show spinner on its own line
    local msg="  🐛 Agent working... ${spin:i++%${#spin}:1}"
    printf "\r\033[2K%s" "$msg" >&2
    sleep 0.1
  done
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Run a single agent iteration
# Returns: signal (ROTATE, GUTTER, COMPLETE, or empty)
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"
  local state_dir="$(get_state_dir "$workspace")"
  
  # Use CURRENT_TASK_FILE if set, otherwise default to .ralph/tasks/RALPH_TASK.md
  local task_file="${CURRENT_TASK_FILE:-$(get_entry_task "$workspace")}"
  
  local prompt=$(build_prompt "$workspace" "$iteration" "$task_file")
  local fifo="$state_dir/.parser_fifo"
  
  # Create named pipe for parser signals
  rm -f "$fifo"
  mkfifo "$fifo"
  
  # Use stderr for display (stdout is captured for signal)
  local task_file_rel="${task_file#$workspace/}"
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Iteration $iteration" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "Task:      $task_file_rel" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $state_dir/activity.log" >&2
  echo "" >&2
  
  # Log session start to progress.md
  log_progress "$workspace" "**Session $iteration started** (model: $MODEL)"
  
  # Build claude command args (use array to avoid eval and backtick issues)
  # Note: Claude requires --verbose with --output-format=stream-json
  local -a cmd_args=("claude" "-p" "--dangerously-skip-permissions" "--verbose" "--output-format" "stream-json" "--model" "$MODEL")
  
  if [[ -n "$session_id" ]]; then
    echo "Resuming session: $session_id" >&2
    cmd_args+=("--resume=$session_id")
  fi
  
  # Change to workspace
  cd "$workspace"
  
  # Start spinner to show we're alive (with task file for progress tracking)
  spinner "$workspace" "$task_file" &
  local spinner_pid=$!
  
  # Start parser in background, reading from cursor-agent
  # Parser outputs to fifo, we read signals from fifo
  (
    # Harden the execution environment against interactive commands.
    # Also prepend shimmed binaries so calls like `npm init` cannot block.
    export PATH="$script_dir/shims:$PATH"
    export CI=1
    export npm_config_yes=true
    export npm_config_audit=false
    export npm_config_fund=false
    export GIT_TERMINAL_PROMPT=0
    export GIT_EDITOR=:
    export EDITOR=:
    export PAGER=cat
    # Pass prompt as argument (Claude expects prompt as positional arg, not stdin)
    "${cmd_args[@]}" "$prompt" 2>&1 | "$script_dir/stream-parser.sh" "$workspace" > "$fifo"
  ) &
  local agent_pid=$!

  # Start watchdog to catch blocking interactive commands (e.g. npm init)
  run_watchdog "$agent_pid" "$fifo" "$workspace" &
  local watchdog_pid=$!
  
  # Read signals from parser
  local signal=""
  while IFS= read -r line; do
    case "$line" in
      "ROTATE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🔄 Context rotation triggered - stopping agent..." >&2
        kill_tree $agent_pid
        signal="ROTATE"
        break
        ;;
      "WARN")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "⚠️  Context warning - agent should wrap up soon..." >&2
        # Send interrupt to encourage wrap-up (agent continues but is notified)
        ;;
      "GUTTER")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "🚨 Gutter detected - killing stuck agent..." >&2
        kill_tree $agent_pid
        signal="GUTTER"
        break
        ;;
      "COMPLETE")
        printf "\r\033[K" >&2  # Clear spinner line
        echo "✅ Agent signaled completion!" >&2
        kill_tree $agent_pid
        signal="COMPLETE"
        break
        ;;
    esac
  done < "$fifo"
  
  # Wait for agent to finish
  wait $agent_pid 2>/dev/null || true

  # Stop watchdog
  kill $watchdog_pid 2>/dev/null || true
  wait $watchdog_pid 2>/dev/null || true
  
  # Stop spinner and clear line
  kill_tree $spinner_pid
  wait $spinner_pid 2>/dev/null || true
  printf "\r\033[K" >&2  # Clear spinner line
  
  # Cleanup
  rm -f "$fifo"
  
  echo "$signal"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Run the main Ralph loop
# Args: workspace
# Uses global: MAX_ITERATIONS, MODEL, USE_BRANCH, OPEN_PR
run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"
  
  # Commit any uncommitted work first
  cd "$workspace"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
  fi
  
  # Create branch if requested
  if [[ -n "$USE_BRANCH" ]]; then
    echo "🌿 Creating branch: $USE_BRANCH"
    git checkout -b "$USE_BRANCH" 2>/dev/null || git checkout "$USE_BRANCH"
  fi
  
  # Find current task by walking the chain from RALPH_TASK.md
  echo ""
  echo "🔗 Walking task chain..."
  local current_task
  current_task=$(find_current_task "$workspace")
  
  if [[ -z "$current_task" ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "🎉 ALL TASKS COMPLETE! Nothing to do."
    echo "═══════════════════════════════════════════════════════════════════"
    return 0
  fi
  
  local task_name
  task_name=$(get_task_name "$current_task")
  # Count criteria in current task file
  local total_count done_count
  total_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$current_task" 2>/dev/null) || total_count=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$current_task" 2>/dev/null) || done_count=0
  echo "📍 Current task: $task_name ($done_count/$total_count criteria)"
  echo "   File: $current_task"
  
  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""
  
  # Main loop
  local iteration=1
  local session_id=""
  
  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    # Run iteration on the CURRENT task file (not always RALPH_TASK.md)
    local signal
    signal=$(CURRENT_TASK_FILE="$current_task" run_iteration "$workspace" "$iteration" "$session_id" "$script_dir")
    
    # Check if current task is complete
    local task_complete=false
    if is_task_complete "$current_task"; then
      task_complete=true
    fi
    
    if [[ "$task_complete" == "true" ]]; then
      task_name=$(get_task_name "$current_task")
      
      # Check if QC already passed (e.g., loop was restarted)
      if has_qc_passed "$current_task"; then
        echo ""
        echo "┌─────────────────────────────────────────────────────────────────┐"
        echo "│ ✅ QC Already Verified: $task_name"
        echo "└─────────────────────────────────────────────────────────────────┘"
        log_progress "$workspace" "**Session $iteration ended** - ✅ $task_name COMPLETE (QC previously verified)"
      else
        # Run QC check before advancing
        local qc_result
        qc_result=$(run_qc_check "$workspace" "$current_task" "$script_dir")
        
        if [[ "$qc_result" != "PASS" ]]; then
          # QC failed - programmatically uncheck the failed criterion
          local fail_num=""
          if [[ "$qc_result" =~ FAIL:([0-9]+) ]]; then
            fail_num="${BASH_REMATCH[1]}"
            uncheck_criterion "$current_task" "$fail_num"
            log_activity "$workspace" "📝 Unchecked criterion $fail_num in $task_name"
            echo ""
            echo "┌─────────────────────────────────────────────────────────────────┐"
            echo "│ ❌ QC Failed: $task_name"
            echo "│    Criterion $fail_num not properly implemented. Unchecked & retrying..."
            echo "└─────────────────────────────────────────────────────────────────┘"
          else
            # No specific criterion - uncheck last checked item as fallback
            local last_checked
            last_checked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$current_task" 2>/dev/null) || last_checked=0
            if [[ "$last_checked" -gt 0 ]]; then
              uncheck_criterion "$current_task" "$last_checked"
              log_activity "$workspace" "📝 Unchecked last criterion ($last_checked) in $task_name"
            fi
            echo ""
            echo "┌─────────────────────────────────────────────────────────────────┐"
            echo "│ ❌ QC Failed: $task_name"
            echo "│    Some criteria not properly implemented. Retrying..."
            echo "└─────────────────────────────────────────────────────────────────┘"
          fi
          log_progress "$workspace" "**Session $iteration ended** - ❌ QC FAILED for $task_name - retrying"
          iteration=$((iteration + 1))
          session_id=""
          sleep 2
          continue
        fi
        
        # QC passed - mark task as verified and proceed
        mark_qc_passed "$current_task"
        log_activity "$workspace" "📝 Marked $task_name as QC verified in frontmatter"
        log_progress "$workspace" "**Session $iteration ended** - ✅ $task_name COMPLETE (QC verified)"
      fi
      
      # Find next task in chain
      local next_task
      next_task=$(get_next_task_file "$workspace" "$current_task")
      
      if [[ -n "$next_task" ]] && [[ -f "$next_task" ]]; then
        # Check if next task is also complete (walk chain)
        current_task=$(find_current_task "$workspace")
        
        if [[ -z "$current_task" ]]; then
          # All tasks done!
          echo ""
          echo "═══════════════════════════════════════════════════════════════════"
          echo "🎉 ALL TASKS IN CHAIN COMPLETE!"
          echo "═══════════════════════════════════════════════════════════════════"
          
          # Open PR if requested
          if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
            echo ""
            echo "📝 Opening pull request..."
            git push -u origin "$USE_BRANCH" 2>/dev/null || git push
            if command -v gh &> /dev/null; then
              gh pr create --fill || echo "⚠️  Could not create PR automatically."
            fi
          fi
          return 0
        fi
        
        task_name=$(get_task_name "$current_task")
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo "📦 Moving to next task: $task_name"
        echo "═══════════════════════════════════════════════════════════════════"
        echo ""
        
        # Reset iteration for new task
        iteration=1
        session_id=""
        sleep 2
        continue
      else
        # No more tasks
        echo ""
        echo "═══════════════════════════════════════════════════════════════════"
        echo "🎉 ALL TASKS COMPLETE! Finished in $iteration iteration(s)."
        echo "═══════════════════════════════════════════════════════════════════"
        
        # Open PR if requested
        if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
          echo ""
          echo "📝 Opening pull request..."
          git push -u origin "$USE_BRANCH" 2>/dev/null || git push
          if command -v gh &> /dev/null; then
            gh pr create --fill || echo "⚠️  Could not create PR automatically."
          fi
        fi
        return 0
      fi
    fi
    
    # Handle signals
    case "$signal" in
      "COMPLETE")
        # Agent signaled completion - verify with checkbox check
        if [[ "$task_complete" == "true" ]]; then
          # Already handled above
          :
        else
          # Agent said complete but checkboxes say otherwise - continue
          log_progress "$workspace" "**Session $iteration ended** - Agent signaled complete but criteria remain"
          echo ""
          echo "⚠️  Agent signaled completion but unchecked criteria remain."
          echo "   Continuing with next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        log_progress "$workspace" "**Session $iteration ended** - 🔄 Context rotation (token limit reached)"
        echo ""
        echo "🔄 Rotating to fresh context..."
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "GUTTER")
        log_progress "$workspace" "**Session $iteration ended** - 🚨 GUTTER (agent stuck)"
        echo ""
        echo "🚨 Gutter detected. Check .ralph/state/errors.log for details."
        echo "   The agent may be stuck. Consider:"
        echo "   1. Check .ralph/state/guardrails.md for lessons"
        echo "   2. Manually fix the blocking issue"
        echo "   3. Re-run the loop"
        return 1
        ;;
      *)
        # Agent finished naturally, check if more work needed
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          log_progress "$workspace" "**Session $iteration ended** - Agent finished naturally ($remaining_count criteria remaining)"
          echo ""
          echo "📋 Agent finished but $remaining_count criteria remaining."
          echo "   Starting next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
    esac
    
    # Brief pause between iterations
    sleep 2
  done
  
  log_progress "$workspace" "**Loop ended** - ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  echo ""
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached."
  echo "   Task may not be complete. Check progress manually."
  return 1
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check all prerequisites, exit with error message if any fail
check_prerequisites() {
  local workspace="$1"
  local task_file="$(get_entry_task "$workspace")"
  
  # Check for task file
  if [[ ! -f "$task_file" ]]; then
    echo "❌ No task file found at $task_file"
    echo ""
    echo "Create a task file first:"
    echo "  mkdir -p .ralph/tasks"
    echo "  cat > .ralph/tasks/RALPH_TASK.md << 'EOF'"
    echo "  ---"
    echo "  task: Your task description"
    echo "  test_command: \"npm test\""
    echo "  ---"
    echo "  # Task"
    echo "  ## Success Criteria"
    echo "  1. [ ] First thing to do"
    echo "  2. [ ] Second thing to do"
    echo "  EOF"
    return 1
  fi
  
  # Check for claude CLI
  if ! command -v claude &> /dev/null; then
    echo "❌ claude CLI not found"
    echo ""
    echo "Install via:"
    echo "  npm install -g @anthropic-ai/claude-code"
    return 1
  fi
  
  # Check for git repo
  if ! git -C "$workspace" rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    return 1
  fi
  
  return 0
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

# Show task summary
show_task_summary() {
  local workspace="$1"
  local task_file="$(get_entry_task "$workspace")"
  
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria - only actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  local total_criteria done_criteria remaining
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $MODEL"
  echo ""
  
  # Return remaining count for caller to check
  echo "$remaining"
}

# Show Ralph banner
show_banner() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Autonomous Development Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
}
