#!/usr/bin/env bash
# Wrapper: run Cursor CLI (agent) in the workspace, copy new/modified files
# to output_dir, extract metrics from the stream-json event stream.
#
# Usage: run-cursor.sh <prompt> <workspace> <output_dir> [model]
set -euo pipefail

PROMPT="$1"
WORKSPACE="$2"
OUTPUT_DIR="$3"
MODEL="${4:-grok-4.5-xhigh}"

AGENT="${CURSOR_BIN:-$(command -v agent 2>/dev/null || echo "$HOME/.local/bin/agent")}"

mkdir -p "$WORKSPACE" "$OUTPUT_DIR"
cd "$WORKSPACE"

# Snapshot pre-existing files with checksums to detect both new and modified files
PRE_CHECKSUMS=$(mktemp)
EVENT_LOG=$(mktemp)
POST_CHECKSUMS=$(mktemp)
trap 'rm -f "$PRE_CHECKSUMS" "$POST_CHECKSUMS" "$EVENT_LOG"' EXIT

find . -maxdepth 3 -type f \
  -not -path './.git/*' -not -path './.cursor/*' \
  -not -path './output/*' -not -path './.claude/*' \
  -exec md5sum {} + 2>/dev/null | sort > "$PRE_CHECKSUMS" || true

# Run cursor agent — capture stream-json to a temp file, stream to stdout for harness
set +e
"$AGENT" -p \
  --force \
  --trust \
  --output-format stream-json \
  --model "$MODEL" \
  --workspace "$WORKSPACE" \
  "$PROMPT" \
  2>/dev/null | tee "$EVENT_LOG"
EXIT_CODE=${PIPESTATUS[0]}
set -e

# Snapshot post-run files with checksums
find . -maxdepth 3 -type f \
  -not -path './.git/*' -not -path './.cursor/*' \
  -not -path './output/*' -not -path './.claude/*' \
  -exec md5sum {} + 2>/dev/null | sort > "$POST_CHECKSUMS" || true

# Copy new and modified files to output_dir
comm -13 "$PRE_CHECKSUMS" "$POST_CHECKSUMS" | awk '{print $2}' | while IFS= read -r f; do
  target_dir="$OUTPUT_DIR/$(dirname "$f")"
  mkdir -p "$target_dir"
  cp "$f" "$OUTPUT_DIR/$f" 2>/dev/null || true
done

# Extract metrics from stream-json events
_EVENT_LOG="$EVENT_LOG" _OUTPUT_DIR="$OUTPUT_DIR" _MODEL="$MODEL" \
python3 -c "
import json, os

# Published pricing per 1M tokens (add models as needed)
PRICING = {
    'grok-4.5':  {'input': 2.00, 'cache_read': 0.50, 'cache_write': 2.00, 'output': 6.00},
    'grok-4.3':  {'input': 1.25, 'cache_read': 0.31, 'cache_write': 1.25, 'output': 2.50},
    'gpt-5.4':   {'input': 2.50, 'cache_read': 0.63, 'cache_write': 2.50, 'output': 10.00},
    'gpt-5.2':   {'input': 2.50, 'cache_read': 0.63, 'cache_write': 2.50, 'output': 10.00},
}

total_input = 0
total_output = 0
cache_read = 0
cache_write = 0
num_turns = 0
model_name = os.environ['_MODEL']

for line in open(os.environ['_EVENT_LOG']):
    line = line.strip()
    if not line or not line.startswith('{'):
        continue
    try:
        evt = json.loads(line)
    except json.JSONDecodeError:
        continue

    # Extract model from system/init event
    if evt.get('type') == 'system' and evt.get('subtype') == 'init':
        model_name = evt.get('model', model_name)

    # Count assistant turns
    if evt.get('type') == 'assistant':
        num_turns += 1

    # Extract usage from result event
    if evt.get('type') == 'result':
        usage = evt.get('usage', {})
        total_input += usage.get('inputTokens', 0)
        total_output += usage.get('outputTokens', 0)
        cache_read += usage.get('cacheReadTokens', 0)
        cache_write += usage.get('cacheWriteTokens', 0)

# Calculate cost from pricing table
cost_usd = None
cli_model = os.environ['_MODEL']
for prefix, rates in PRICING.items():
    if prefix in cli_model:
        cost_usd = round(
            (total_input * rates['input']
             + cache_read * rates['cache_read']
             + cache_write * rates['cache_write']
             + total_output * rates['output']) / 1_000_000,
            6,
        )
        break

metrics = {
    'token_usage': {
        'input': total_input + cache_read,
        'output': total_output,
        'cache_read': cache_read,
        'cache_write': cache_write,
    },
    'cost_usd': cost_usd,
    'num_turns': num_turns if num_turns > 0 else None,
    'model': model_name,
}
with open(os.path.join(os.environ['_OUTPUT_DIR'], 'metrics.json'), 'w') as f:
    json.dump(metrics, f, indent=2)
" 2>/dev/null || true

exit $EXIT_CODE
