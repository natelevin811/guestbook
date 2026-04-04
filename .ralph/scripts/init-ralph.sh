#!/bin/bash
# Ralph Wiggum: Initialize Ralph in a project
# Sets up Ralph tracking for CLI mode
#
# Directory structure:
#   .ralph/
#   ├── scripts/    # Shell scripts (optional, for portable installs)
#   ├── state/      # Runtime state (progress.md, activity.log, etc.)
#   └── tasks/      # Task files (RALPH_TASK.md entry point)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

echo "═══════════════════════════════════════════════════════════════════"
echo "🐛 Ralph Wiggum Initialization"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Check if we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "⚠️  Warning: Not in a git repository."
  echo "   Ralph works best with git for state persistence."
  echo ""
  read -p "Continue anyway? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Check for claude CLI
if ! command -v claude &> /dev/null; then
  echo "⚠️  Warning: claude CLI not found."
  echo "   Install via: npm install -g @anthropic-ai/claude-code"
  echo ""
fi

# Create directories
mkdir -p .ralph/state
mkdir -p .ralph/tasks
mkdir -p .ralph/scripts

# =============================================================================
# CREATE RALPH_TASK.md IF NOT EXISTS
# =============================================================================

if [[ ! -f ".ralph/tasks/RALPH_TASK.md" ]]; then
  echo "📝 Creating .ralph/tasks/RALPH_TASK.md template..."
  if [[ -f "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" ]]; then
    cp "$SKILL_DIR/assets/RALPH_TASK_TEMPLATE.md" .ralph/tasks/RALPH_TASK.md
  else
    cat > .ralph/tasks/RALPH_TASK.md << 'EOF'
---
task: Your task description here
test_command: "npm test"
---

# Task

Describe what you want to accomplish.

## Success Criteria

1. [ ] First thing to complete
2. [ ] Second thing to complete
3. [ ] Third thing to complete

## Context

Any additional context the agent should know.
EOF
  fi
  echo "   Edit .ralph/tasks/RALPH_TASK.md to define your task."
else
  echo "✓ .ralph/tasks/RALPH_TASK.md already exists"
fi

# =============================================================================
# INITIALIZE STATE FILES
# =============================================================================

echo "📁 Initializing .ralph/state/ directory..."

cat > .ralph/state/guardrails.md << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

(Signs added from observed failures will appear below)

EOF

cat > .ralph/state/progress.md << 'EOF'
# Progress Log

> Updated by the agent after significant work.

## Summary

- Iterations completed: 0
- Current status: Initialized

## How This Works

Progress is tracked in THIS FILE, not in LLM context.
When context is rotated (fresh agent), the new agent reads this file.
This is how Ralph maintains continuity across iterations.

## Session History

EOF

cat > .ralph/state/errors.log << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF

cat > .ralph/state/activity.log << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF

echo "0" > .ralph/state/.iteration

# =============================================================================
# INSTALL SCRIPTS (OPTIONAL)
# =============================================================================

echo "📦 Installing scripts..."

# Copy scripts to .ralph/scripts for portable installs
if [[ -d "$SCRIPT_DIR" ]]; then
  cp "$SCRIPT_DIR/"*.sh .ralph/scripts/ 2>/dev/null || true
  chmod +x .ralph/scripts/*.sh 2>/dev/null || true
  
  # Copy shims directory if it exists
  if [[ -d "$SCRIPT_DIR/shims" ]]; then
    cp -r "$SCRIPT_DIR/shims" .ralph/scripts/
    chmod +x .ralph/scripts/shims/* 2>/dev/null || true
  fi
  
  echo "✓ Scripts installed to .ralph/scripts/"
fi

# =============================================================================
# UPDATE .gitignore
# =============================================================================

if [[ -f ".gitignore" ]]; then
  # Don't gitignore .ralph/ - we want it tracked for state persistence
  if ! grep -q "ralph-config.json" .gitignore; then
    echo "" >> .gitignore
    echo "# Ralph config (may contain API keys)" >> .gitignore
    echo ".cursor/ralph-config.json" >> .gitignore
  fi
  echo "✓ Updated .gitignore"
else
  cat > .gitignore << 'EOF'
# Ralph config (may contain API keys)
.cursor/ralph-config.json
EOF
  echo "✓ Created .gitignore"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "✅ Ralph initialized!"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Directory structure:"
echo "  .ralph/"
echo "  ├── scripts/              - Shell scripts"
echo "  ├── state/"
echo "  │   ├── guardrails.md     - Lessons learned (agent updates)"
echo "  │   ├── progress.md       - Progress log (agent updates)"
echo "  │   ├── activity.log      - Tool call log (parser updates)"
echo "  │   └── errors.log        - Failure log (parser updates)"
echo "  └── tasks/"
echo "      └── RALPH_TASK.md     - Define your task here (entry point)"
echo ""
echo "Next steps:"
echo "  1. Edit .ralph/tasks/RALPH_TASK.md to define your task and criteria"
echo "  2. Run: .ralph/scripts/ralph-loop.sh"
echo ""
echo "The agent will work autonomously, rotating context as needed."
echo "Monitor progress: tail -f .ralph/state/activity.log"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
