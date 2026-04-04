#!/bin/bash
# Ralph Wiggum: Stream Parser (Claude Code compatible)
#
# Parses claude stream-json output in real-time.
# Tracks token usage, detects failures/gutter, writes to .ralph/state/ logs.
#
# Usage:
#   claude -p --verbose --output-format stream-json "..." | ./stream-parser.sh /path/to/workspace
#
# Outputs to stdout:
#   - ROTATE when threshold hit (150k tokens)
#   - WARN when approaching limit (120k tokens)
#   - GUTTER when stuck pattern detected
#   - COMPLETE when agent outputs <ralph>COMPLETE</ralph>
#
# Writes to .ralph/state/:
#   - activity.log: all operations with context health
#   - errors.log: failures and gutter detection

set -euo pipefail

WORKSPACE="${1:-.}"
RALPH_DIR="$WORKSPACE/.ralph/state"

# Ensure .ralph/state directory exists
mkdir -p "$RALPH_DIR"

# Token thresholds (rotate early to maintain quality)
WARN_THRESHOLD=80000
ROTATE_THRESHOLD=100000

# Tracking state - using API-reported values for accuracy
TOOL_CALLS=0
WARN_SENT=0

# API-reported token counts (most accurate)
LAST_CACHE_READ=0      # cache_read_input_tokens - actual context being used
TOTAL_OUTPUT_TOKENS=0  # Cumulative output tokens (includes thinking)
TOTAL_CACHE_CREATION=0 # New content being cached

# Byte-based fallback tracking
BYTES_READ=0
BYTES_WRITTEN=0
ASSISTANT_CHARS=0
SHELL_OUTPUT_CHARS=0
PROMPT_CHARS=3000

# Gutter detection - use temp files instead of associative arrays (macOS bash 3.x compat)
FAILURES_FILE=$(mktemp)
WRITES_FILE=$(mktemp)
trap "rm -f $FAILURES_FILE $WRITES_FILE" EXIT

calc_tokens() {
  # Use API-reported values when available (most accurate)
  # cache_read = actual context Claude is working with
  # output_tokens = cumulative output including thinking
  
  if [[ $LAST_CACHE_READ -gt 0 ]]; then
    # API-based: cache_read represents current context, add cumulative output
    echo $((LAST_CACHE_READ + TOTAL_OUTPUT_TOKENS))
  else
    # Fallback to byte-based estimate
    local input_bytes=$((PROMPT_CHARS + BYTES_READ + BYTES_WRITTEN + ASSISTANT_CHARS + SHELL_OUTPUT_CHARS))
    local input_tokens=$((input_bytes / 4))
    echo $((input_tokens + TOTAL_OUTPUT_TOKENS))
  fi
}

# Log to activity.log with contextual emoji
log_activity() {
  local message="$1"
  local timestamp=$(date '+%H:%M:%S')
  local emoji="📍"
  
  # Pick emoji based on message content
  case "$message" in
    SESSION\ START*) emoji="🚀" ;;
    SESSION\ END*) emoji="🏁" ;;
    TOOL\ READ*|READ\ *) emoji="📖" ;;
    TOOL\ Write*|TOOL\ Edit*) emoji="✏️" ;;
    TOOL\ Bash*) emoji="💻" ;;
    TOOL\ Grep*) emoji="🔍" ;;
    TOOL\ Glob*) emoji="📂" ;;
    TOOL\ TodoWrite*) emoji="📝" ;;
    TOOL\ TaskOutput*) emoji="📋" ;;
    TOOL\ KillShell*) emoji="💀" ;;
    *QC*PASS*) emoji="✅" ;;
    *QC*FAIL*) emoji="❌" ;;
    *QC*START*) emoji="🔍" ;;
    *COMPLETE*) emoji="✅" ;;
    *GUTTER*) emoji="🚨" ;;
    *) emoji="⚡" ;;
  esac
  
  echo "[$timestamp] $emoji $message" >> "$RALPH_DIR/activity.log"
}

# Log to errors.log
log_error() {
  local message="$1"
  local timestamp=$(date '+%H:%M:%S')
  
  echo "[$timestamp] $message" >> "$RALPH_DIR/errors.log"
}

# Log token status with health indicator
log_token_status() {
  local tokens=$(calc_tokens)
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  local timestamp=$(date '+%H:%M:%S')
  
  # Health emoji based on percentage
  local emoji="🟢"
  if [[ $pct -ge 90 ]]; then
    emoji="🔴"
  elif [[ $pct -ge 80 ]]; then
    emoji="🟠"
  elif [[ $pct -ge 60 ]]; then
    emoji="🟡"
  fi
  
  local breakdown="[ctx:${LAST_CACHE_READ}tok out:${TOTAL_OUTPUT_TOKENS}tok cache+:${TOTAL_CACHE_CREATION}tok]"
  echo "[$timestamp] $emoji TOKENS: $tokens / $ROTATE_THRESHOLD ($pct%) $breakdown" >> "$RALPH_DIR/activity.log"
}

# NOTE: Terminal display moved to spinner in ralph-common.sh to avoid conflicts
# This function is kept as no-op for backward compatibility
show_recent_activity() {
  :
}

# Check for token thresholds and trigger rotation if needed
check_gutter() {
  local tokens=$(calc_tokens)
  
  # Check rotation threshold
  if [[ $tokens -ge $ROTATE_THRESHOLD ]]; then
    log_activity "⚠️ ROTATE: Token threshold reached ($tokens >= $ROTATE_THRESHOLD)"
    echo "ROTATE" 2>/dev/null || true
    return
  fi
  
  # Check warning threshold (only emit once per session)
  if [[ $tokens -ge $WARN_THRESHOLD ]] && [[ $WARN_SENT -eq 0 ]]; then
    log_activity "⚠️ WARN: Approaching token limit ($tokens >= $WARN_THRESHOLD)"
    WARN_SENT=1
    echo "WARN" 2>/dev/null || true
  fi
}

# Track shell command failure
track_shell_failure() {
  local cmd="$1"
  local exit_code="$2"
  
  if [[ $exit_code -ne 0 ]]; then
    # Count failures for this command (grep -c exits 1 if no match, so use || true)
    local count
    count=$(grep -c "^${cmd}$" "$FAILURES_FILE" 2>/dev/null) || count=0
    count=$((count + 1))
    echo "$cmd" >> "$FAILURES_FILE"
    
    log_error "SHELL FAIL: $cmd → exit $exit_code (attempt $count)"
    
    if [[ $count -ge 3 ]]; then
      log_error "⚠️ GUTTER: same command failed ${count}x"
      echo "GUTTER" 2>/dev/null || true
    fi
  fi
}

# Track file writes for thrashing detection
track_file_write() {
  local path="$1"
  local now=$(date +%s)
  
  # Log write with timestamp
  echo "$now:$path" >> "$WRITES_FILE"
  
  # Count writes to this file in last 10 minutes
  local cutoff=$((now - 600))
  local count=$(awk -F: -v cutoff="$cutoff" -v path="$path" '
    $1 >= cutoff && $2 == path { count++ }
    END { print count+0 }
  ' "$WRITES_FILE")
  
  # Check for thrashing (5+ writes in 10 minutes)
  if [[ $count -ge 5 ]]; then
    log_error "⚠️ THRASHING: $path written ${count}x in 10 min"
    echo "GUTTER" 2>/dev/null || true
  fi
}

# Process a single JSON line from stream (Claude Code format)
process_line() {
  local line="$1"
  
  # Skip empty lines
  [[ -z "$line" ]] && return
  
  # Parse JSON type
  local type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || return
  local subtype=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null) || true
  
  case "$type" in
    "system")
      if [[ "$subtype" == "init" ]]; then
        local model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
        log_activity "SESSION START: model=$model"
      fi
      ;;
      
    "assistant")
      # Track assistant message characters and detect tool use
      local content_type=$(echo "$line" | jq -r '.message.content[0].type // empty' 2>/dev/null) || content_type=""
      
      if [[ "$content_type" == "text" ]]; then
        local text=$(echo "$line" | jq -r '.message.content[0].text // empty' 2>/dev/null) || text=""
        if [[ -n "$text" ]]; then
          local chars=${#text}
          ASSISTANT_CHARS=$((ASSISTANT_CHARS + chars))
          
          # Check for completion sigil
          if [[ "$text" == *"<ralph>COMPLETE</ralph>"* ]]; then
            log_activity "✅ Agent signaled COMPLETE"
            echo "COMPLETE" 2>/dev/null || true
          fi
          
          # Check for gutter sigil
          if [[ "$text" == *"<ralph>GUTTER</ralph>"* ]]; then
            log_activity "🚨 Agent signaled GUTTER (stuck)"
            echo "GUTTER" 2>/dev/null || true
          fi
          
          # Check for QC pass sigil
          if [[ "$text" == *"<qc>PASS</qc>"* ]]; then
            log_activity "✅ QC agent verified: PASS"
            echo "QC_PASS" 2>/dev/null || true
          fi
          
          # Check for QC fail sigil
          if [[ "$text" =~ \<qc\>FAIL(:([0-9]+))?\</qc\> ]]; then
            local fail_num="${BASH_REMATCH[2]:-unknown}"
            log_activity "❌ QC agent failed verification: criterion $fail_num"
            echo "QC_FAIL:$fail_num" 2>/dev/null || true
          fi
        fi
      elif [[ "$content_type" == "tool_use" ]]; then
        # Claude embeds tool calls in assistant messages
        TOOL_CALLS=$((TOOL_CALLS + 1))
        local tool_name=$(echo "$line" | jq -r '.message.content[0].name // empty' 2>/dev/null) || tool_name=""
        local tool_input=$(echo "$line" | jq -c '.message.content[0].input // {}' 2>/dev/null) || tool_input="{}"
        
        # Log tool call start
        case "$tool_name" in
          "Read")
            local path=$(echo "$tool_input" | jq -r '.file_path // .path // "unknown"' 2>/dev/null) || path="unknown"
            log_activity "TOOL READ: $path (started)"
            ;;
          "Write"|"Edit")
            local path=$(echo "$tool_input" | jq -r '.file_path // .path // "unknown"' 2>/dev/null) || path="unknown"
            log_activity "TOOL $tool_name: $path (started)"
            ;;
          "Bash")
            local cmd=$(echo "$tool_input" | jq -r '.command // "unknown"' 2>/dev/null) || cmd="unknown"
            # Check for known interactive commands
            if [[ "$cmd" =~ ^npm[[:space:]]+init($|[[:space:]]+[^-]) ]] && [[ ! "$cmd" =~ -y ]]; then
              log_error "🚨 BLOCKED: Interactive command detected: $cmd (use 'npm init -y' instead)"
              echo "GUTTER" 2>/dev/null || true
            elif [[ "$cmd" =~ ^git[[:space:]]+commit($|[[:space:]]) ]] && [[ ! "$cmd" =~ -m ]]; then
              log_error "🚨 BLOCKED: Interactive command detected: $cmd (use 'git commit -m \"message\"' instead)"
              echo "GUTTER" 2>/dev/null || true
            elif [[ "$cmd" =~ ^python($|[[:space:]]*$) ]] || [[ "$cmd" =~ ^python3($|[[:space:]]*$) ]]; then
              log_error "🚨 BLOCKED: Interactive command detected: $cmd (use 'python script.py' instead)"
              echo "GUTTER" 2>/dev/null || true
            elif [[ "$cmd" =~ ^node($|[[:space:]]*$) ]]; then
              log_error "🚨 BLOCKED: Interactive command detected: $cmd (use 'node script.js' instead)"
              echo "GUTTER" 2>/dev/null || true
            fi
            log_activity "TOOL Bash: ${cmd:0:60}... (started)"
            ;;
          *)
            log_activity "TOOL $tool_name (started)"
            ;;
        esac
      fi
      
      # Track token usage from API (most accurate source)
      local output_tokens=$(echo "$line" | jq -r '.message.usage.output_tokens // 0' 2>/dev/null) || output_tokens=0
      local cache_read=$(echo "$line" | jq -r '.message.usage.cache_read_input_tokens // 0' 2>/dev/null) || cache_read=0
      local cache_create=$(echo "$line" | jq -r '.message.usage.cache_creation_input_tokens // 0' 2>/dev/null) || cache_create=0
      
      # Update tracking
      if [[ $output_tokens -gt 0 ]]; then
        TOTAL_OUTPUT_TOKENS=$((TOTAL_OUTPUT_TOKENS + output_tokens))
      fi
      if [[ $cache_read -gt 0 ]]; then
        LAST_CACHE_READ=$cache_read  # This represents current context size
      fi
      if [[ $cache_create -gt 0 ]]; then
        TOTAL_CACHE_CREATION=$((TOTAL_CACHE_CREATION + cache_create))
      fi
      ;;
      
    "user")
      # Tool results come in user messages
      local tool_result=$(echo "$line" | jq -r '.tool_use_result // empty' 2>/dev/null) || tool_result=""
      
      if [[ -n "$tool_result" ]]; then
        local result_type=$(echo "$tool_result" | jq -r '.type // empty' 2>/dev/null) || result_type=""
        
        if [[ "$result_type" == "text" ]]; then
          # Check if it's a file read result
          local file_path=$(echo "$tool_result" | jq -r '.file.filePath // empty' 2>/dev/null) || file_path=""
          if [[ -n "$file_path" ]]; then
            local num_lines=$(echo "$tool_result" | jq -r '.file.numLines // 0' 2>/dev/null) || num_lines=0
            local content=$(echo "$tool_result" | jq -r '.file.content // ""' 2>/dev/null) || content=""
            local bytes=${#content}
            BYTES_READ=$((BYTES_READ + bytes))
            
            local kb=$(echo "scale=1; $bytes / 1024" | bc 2>/dev/null || echo "$((bytes / 1024))")
            log_activity "READ $file_path ($num_lines lines, ~${kb}KB)"
          fi
        fi
        
        # Check gutter after tool result
        check_gutter
        
        # Show progress to terminal
        show_recent_activity
      fi
      ;;
      
    "result")
      # Session end with stats
      local duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration=0
      local cost=$(echo "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null) || cost=0
      local tokens=$(calc_tokens)
      log_activity "SESSION END: ${duration}ms, ~$tokens tokens (estimated), \$$cost"
      ;;
  esac
}

# Main loop: read JSON lines from stdin
main() {
  # Initialize activity log for this session
  echo "" >> "$RALPH_DIR/activity.log"
  echo "╔═══════════════════════════════════════════════════════════════╗" >> "$RALPH_DIR/activity.log"
  echo "║ 🐛 Ralph Session: $(date '+%Y-%m-%d %H:%M:%S')                  ║" >> "$RALPH_DIR/activity.log"
  echo "╚═══════════════════════════════════════════════════════════════╝" >> "$RALPH_DIR/activity.log"
  
  # Debug: log that we're starting to read
  echo "[$(date '+%H:%M:%S')] 🔌 Stream parser connected, awaiting Claude..." >> "$RALPH_DIR/activity.log"
  
  # Track last token log time
  local last_token_log=$(date +%s)
  
  while IFS= read -r line; do
    process_line "$line"
    
    # Log token status every 30 seconds
    local now=$(date +%s)
    if [[ $((now - last_token_log)) -ge 30 ]]; then
      log_token_status
      show_recent_activity
      last_token_log=$now
    fi
  done
  
  # Final token status
  log_token_status
}

main
