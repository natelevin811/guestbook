#!/bin/bash
# Ralph Wiggum: The Loop (CLI Mode)
#
# Runs claude locally with stream-json parsing for accurate token tracking.
# Handles context rotation via --resume when thresholds are hit.
#
# This script is for power users and scripting. For interactive use, see ralph-setup.sh.
#
# Usage:
#   ./ralph-loop.sh                              # Start from current directory
#   ./ralph-loop.sh /path/to/project             # Start from specific project
#   ./ralph-loop.sh -n 50 -m opus                # Custom iterations and model
#   ./ralph-loop.sh --branch feature/foo --pr   # Create branch and PR
#   ./ralph-loop.sh -y                           # Skip confirmation (for scripting)
#
# Flags:
#   -n, --iterations N     Max iterations (default: 20)
#   -m, --model MODEL      Model to use (default: opus-4.5-thinking)
#   --branch NAME          Create and work on a new branch
#   --pr                   Open PR when complete (requires --branch)
#   -y, --yes              Skip confirmation prompt
#   -h, --help             Show this help
#
# Requirements:
#   - .ralph/tasks/RALPH_TASK.md task file
#   - Git repository
#   - claude CLI installed (npm install -g @anthropic-ai/claude-code)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup function to kill child claude processes on exit
CLEANUP_DONE=0
cleanup() {
  # Only run once
  [[ $CLEANUP_DONE -eq 1 ]] && return
  CLEANUP_DONE=1
  
  echo ""
  echo "🛑 Shutting down Ralph..."
  # Kill any child claude processes
  pkill -P $$ claude 2>/dev/null || true
  # Also kill by name in case they're orphaned
  pkill -f "claude.*--dangerously-skip-permissions" 2>/dev/null || true
  
  # Clear activity log to prevent unbounded growth
  if [[ -n "${WORKSPACE:-}" ]] && [[ -f "$WORKSPACE/.ralph/state/activity.log" ]]; then
    echo "🧹 Clearing activity log..."
    echo "# Activity Log (cleared on shutdown)" > "$WORKSPACE/.ralph/state/activity.log"
  fi
  
  echo "✅ Cleanup complete"
}
trap cleanup EXIT INT TERM

# Source common functions
source "$SCRIPT_DIR/ralph-common.sh"

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  cat << 'EOF'
Ralph Wiggum: The Loop (CLI Mode) - Claude Code Edition

Usage:
  ./ralph-loop.sh [options] [workspace]

Options:
  -n, --iterations N     Max iterations (default: 20)
  -m, --model MODEL      Model to use (default: opus)
  --branch NAME          Create and work on a new branch
  --pr                   Open PR when complete (requires --branch)
  -y, --yes              Skip confirmation prompt
  -h, --help             Show this help

Models (aliases or full names):
  opus                   Claude Opus 4.5 (most capable)
  sonnet                 Claude Sonnet 4.5 (faster, cheaper)
  claude-opus-4-5-20251101    Full model name
  claude-sonnet-4-5-20250514  Full model name

Examples:
  ./ralph-loop.sh                                    # Interactive mode
  ./ralph-loop.sh -n 50                              # 50 iterations max
  ./ralph-loop.sh -m sonnet                          # Use Sonnet model
  ./ralph-loop.sh --branch feature/api --pr -y      # Scripted PR workflow

Environment:
  RALPH_MODEL            Override default model (same as -m flag)

For interactive setup with a beautiful UI, use ralph-setup.sh instead.
EOF
}

# Parse command line arguments
WORKSPACE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    --branch)
      USE_BRANCH="$2"
      shift 2
      ;;
    --pr)
      OPEN_PR=true
      shift
      ;;
    -y|--yes)
      SKIP_CONFIRM=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Use -h for help."
      exit 1
      ;;
    *)
      # Positional argument = workspace
      WORKSPACE="$1"
      shift
      ;;
  esac
done

# =============================================================================
# MAIN
# =============================================================================

main() {
  # Resolve workspace
  if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE="$(pwd)"
  elif [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi

  # Show banner
  show_banner

  # Check prerequisites
  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi

  # Validate: PR requires branch
  if [[ "$OPEN_PR" == "true" ]] && [[ -z "$USE_BRANCH" ]]; then
    echo "❌ --pr requires --branch"
    echo "   Example: ./ralph-loop.sh --branch feature/foo --pr"
    exit 1
  fi

  # Initialize .ralph directory
  init_ralph_dir "$WORKSPACE"

  # Find current task by walking the chain (not just the entry point)
  local task_file
  task_file=$(find_current_task "$WORKSPACE")
  
  if [[ -z "$task_file" ]]; then
    echo "Workspace: $WORKSPACE"
    echo ""
    echo "🎉 ALL TASKS COMPLETE! Nothing to do."
    exit 0
  fi

  echo "Workspace: $WORKSPACE"
  echo "Task:      $task_file"
  echo ""

  # Show task summary
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""

  # Count criteria
  local total_criteria done_criteria remaining
  # Only count actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))

  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $MODEL"
  echo "Max iter: $MAX_ITERATIONS"
  [[ -n "$USE_BRANCH" ]] && echo "Branch:   $USE_BRANCH"
  [[ "$OPEN_PR" == "true" ]] && echo "Open PR:  Yes"
  echo ""

  # Confirm before starting (unless -y flag)
  if [[ "$SKIP_CONFIRM" != "true" ]]; then
    echo "This will run claude locally to work on this task."
    echo "Agent rotates at ~100k tokens or on GUTTER (stuck)."
    echo ""
    echo "Tip: Use ralph-setup.sh for interactive model/option selection."
    echo "     Use -y flag to skip this prompt."
    echo ""
    read -p "Start Ralph loop? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  # Run the loop
  run_ralph_loop "$WORKSPACE" "$SCRIPT_DIR"
  exit $?
}

main
