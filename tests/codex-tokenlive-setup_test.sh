#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/codex-home"

cat > "$TEST_ROOT/bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"object":"list","data":[{"id":"gpt-5.6-sol"},{"id":"claude-sonnet-4"}]}'
EOF

chmod +x "$TEST_ROOT/bin/codex" "$TEST_ROOT/bin/curl"

printf '1\n1\n' |
  env \
    CODEX_HOME="$TEST_ROOT/codex-home" \
    TOKENLIVE_GATEWAY_URL="https://gateway.example/v1" \
    TOKENLIVE_API_KEY="sk-test-key" \
    PATH="$TEST_ROOT/bin:$PATH" \
    bash "$REPO_ROOT/codex-tokenlive-setup.sh" > "$TEST_ROOT/setup.out"

python3 - "$TEST_ROOT/codex-home/models.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as model_file:
    models = json.load(model_file)["models"]

assert len(models) == 2
for model in models:
    assert model["input_modalities"] == ["text", "image"], model["slug"]
    assert model["supports_image_detail_original"] is True, model["slug"]
    assert model["web_search_tool_type"] == "text_and_image", model["slug"]
PY

printf '1\n2\n' |
  env \
    CODEX_HOME="$TEST_ROOT/codex-home" \
    TOKENLIVE_GATEWAY_URL="https://gateway.example/v1" \
    TOKENLIVE_API_KEY="sk-test-key" \
    PATH="$TEST_ROOT/bin:$PATH" \
    bash "$REPO_ROOT/codex-tokenlive-setup.sh" > "$TEST_ROOT/refresh.out"

python3 - "$TEST_ROOT/codex-home/models.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as model_file:
    models = json.load(model_file)["models"]

selected = next(model for model in models if model["slug"] == "claude-sonnet-4")
assert selected["priority"] == 1
for model in models:
    assert model["input_modalities"] == ["text", "image"], model["slug"]
    assert model["supports_image_detail_original"] is True, model["slug"]
    assert model["web_search_tool_type"] == "text_and_image", model["slug"]
PY

printf 'PASS: generated and refreshed TokenLive models support image input\n'
