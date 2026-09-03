#!/usr/bin/env bash
# Codex TokenLive Setup — configuration manager (macOS / Linux)
#
# Run:  bash <(curl -fsSL https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/codex-tokenlive-setup.sh)
#
# After launch, pick a menu item:
#   1 = configure (fetch models from TokenLive gateway, pick model, write config)
#   2 = restore default Codex config

set -uo pipefail

# The whole script is wrapped in { }: bash reads the entire file before executing,
# which avoids curl exiting with (23) write errors when the user hits Ctrl+C
# in the bash <(curl ...) scenario.
{

trap 'printf "\n已取消。\n"; exit 130' INT

SCRIPT_VERSION="1.1.1"
PROVIDER_ID="tokenlive"
DEFAULT_GATEWAY_URL="http://127.0.0.1:2525/v1"
BACKUP_DIRNAME="backup-tokenlive"

SCRIPT_URL="https://raw.githubusercontent.com/tokenlive/tokenlive-deploy/main/codex-tokenlive-setup.sh"
INSTALL_CMD="bash <(curl -fsSL $SCRIPT_URL)"

# ---------------------------------------------------------------- output helpers

if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_RED=$'\033[31m'
  C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_DIM=$'\033[2m'
else
  C_RST=''; C_B=''; C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }
head1(){ printf '\n%s%s%s\n' "$C_B" "$*" "$C_RST"; }

if [ $# -gt 0 ]; then
  die "本脚本不接受命令行参数。
直接运行后按菜单选择：1 配置，2 恢复默认配置，3 清除历史配置缓存。
  $INSTALL_CMD"
fi

# Read user input.
# When stdin is a pipe (printf ... | script, automated tests) read stdin first;
# when stdin is a terminal or exhausted, read /dev/tty to support curl ... | bash.
read_tty() {
  local __var="$1" __prompt="$2" __ans='' __got=1
  if [ ! -t 0 ]; then
    printf '%s' "$__prompt"
    if IFS= read -r __ans; then __got=0; fi
  fi
  if [ "$__got" -ne 0 ] && [ -r /dev/tty ]; then
    printf '%s' "$__prompt" > /dev/tty
    IFS= read -r __ans < /dev/tty || __ans=''
  fi
  eval "$__var=\$__ans"
}

# ---------------------------------------------------------------- paths

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME_DIR/config.toml"
MODELS_PATH="$CODEX_HOME_DIR/models.json"
BACKUP_DIR="$CODEX_HOME_DIR/$BACKUP_DIRNAME"
BACKUP_CONFIG="$BACKUP_DIR/config.toml"
MANIFEST="$BACKUP_DIR/manifest.txt"
CACHE_FILE="$CODEX_HOME_DIR/.tokenlive_cache"

# ~ is verified to work on macOS; with a custom CODEX_HOME an absolute path is safer
if [ -n "${CODEX_HOME:-}" ]; then
  CATALOG_VALUE="$MODELS_PATH"
else
  CATALOG_VALUE="~/.codex/models.json"
fi

# ---------------------------------------------------------------- cache helpers

save_tokenlive_cache() {
  local gw="$1" key="$2" model="${3:-}"
  local tmp="${CACHE_FILE}.tokenlive-tmp.$$"
  {
    printf 'cached_gateway_url=%s\n' "$gw"
    printf 'cached_api_key=%s\n' "$key"
    printf 'cached_model_slug=%s\n' "$model"
    printf 'cached_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$tmp" 2>/dev/null || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$CACHE_FILE" 2>/dev/null || return 1
  chmod 600 "$CACHE_FILE" 2>/dev/null || true
  return 0
}

load_tokenlive_cache() {
  CACHED_GW=''
  CACHED_KEY=''
  CACHED_MODEL=''
  [ -f "$CACHE_FILE" ] || return 1
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      cached_gateway_url) CACHED_GW="$v" ;;
      cached_api_key)     CACHED_KEY="$v" ;;
      cached_model_slug)  CACHED_MODEL="$v" ;;
    esac
  done < "$CACHE_FILE"
  return 0
}

mask_key() {
  local key="$1"
  local len=${#key}
  if [ "$len" -le 8 ]; then
    printf 'sk-****'
  else
    local suffix="${key: -4}"
    printf 'sk-****%s' "$suffix"
  fi
}

# ---------------------------------------------------------------- purge cache (menu 3)

do_purge_cache() {
  head1 "清除 TokenLive 本地历史配置缓存"
  if [ ! -f "$CACHE_FILE" ]; then
    info "未检测到历史配置缓存文件（${CACHE_FILE}），无需清理。"
    exit 0
  fi

  info "将删除以下缓存文件："
  info "  • $CACHE_FILE"
  info ""
  local ans=''
  read_tty ans "确认清除历史配置缓存? 输入 y 继续，其它任意键取消: "
  case "$ans" in
    y|Y|yes|YES) ;;
    *) info "已取消，未做任何修改。"; exit 0 ;;
  esac

  rm -f "$CACHE_FILE"
  ok "历史配置缓存已清除。"
  exit 0
}

# ---------------------------------------------------------------- restore (menu 2)

do_restore() {
  head1 "恢复默认 Codex 配置（删除 tokenlive 相关配置）"
  [ -d "$BACKUP_DIR" ] || die "未找到备份目录：$BACKUP_DIR
没有可还原的内容——可能尚未安装过，或已经还原过了。"

  # 如果尚未生成缓存，尝试从当前 config.toml 中提取 TokenLive 配置并转存，防止配置丢失
  if [ ! -f "$CACHE_FILE" ] && [ -f "$CONFIG_PATH" ]; then
    local cur_gw cur_key cur_model
    cur_gw=$(parse_provider_field "base_url" 2>/dev/null) || cur_gw=''
    cur_key=$(parse_provider_field "experimental_bearer_token" 2>/dev/null) || cur_key=''
    cur_model=$(grep -m1 "^model[[:space:]]*=" "$CONFIG_PATH" 2>/dev/null | sed 's/.*=[[:space:]]*//; s/^"//; s/"$//') || cur_model=''
    if [ -n "$cur_gw" ] && [ -n "$cur_key" ]; then
      save_tokenlive_cache "$cur_gw" "$cur_key" "$cur_model" || true
    fi
  fi

  local had_config=1
  if [ -f "$MANIFEST" ]; then
    if grep -q '^original_config_existed=0$' "$MANIFEST" 2>/dev/null; then
      had_config=0
    fi
  fi

  local n=1
  info ""
  info "将执行以下操作："
  if [ "$had_config" -eq 1 ]; then
    [ -f "$BACKUP_CONFIG" ] || die "备份已损坏：缺少 $BACKUP_CONFIG"
    info "  $n. 删除当前 $CONFIG_PATH"; n=$((n+1))
    info "     ${C_YEL}（安装之后对该文件做的所有修改都会丢失）${C_RST}"
    info "  $n. 用备份恢复 config.toml"; n=$((n+1))
  else
    info "  $n. 删除 $CONFIG_PATH"; n=$((n+1))
    info "     ${C_DIM}（安装前本不存在此文件）${C_RST}"
  fi
  info "  $n. 删除 $MODELS_PATH"; n=$((n+1))
  info "  $n. 删除备份目录 $BACKUP_DIR"
  info ""

  local ans=''
  read_tty ans "确认还原? 输入 y 继续，其它任意键取消: "
  case "$ans" in
    y|Y|yes|YES) ;;
    *) info "已取消，未做任何修改。"; exit 0 ;;
  esac

  rm -f "$MODELS_PATH"
  if [ "$had_config" -eq 1 ]; then
    cp "$BACKUP_CONFIG" "$CONFIG_PATH" || die "恢复 config.toml 失败"
    ok "config.toml 已恢复"
  else
    rm -f "$CONFIG_PATH"
    ok "config.toml 已删除（安装前不存在）"
  fi
  ok "models.json 已删除"

  rm -rf "$BACKUP_DIR"
  ok "备份目录已清理"
  info ""
  ok "还原完成，Codex 配置已回到安装前的状态。"
  if [ -f "$CACHE_FILE" ]; then
    info ""
    ok "TokenLive 历史配置已保留（${CACHE_FILE}），下次配置可一键沿用。"
    info "${C_DIM}如需彻底清除该配置记录，可再次运行本脚本选择 3。${C_RST}"
  fi
  info ""
  info "${C_DIM}如需再次安装：$INSTALL_CMD${C_RST}"
  exit 0
}

# ---------------------------------------------------------------- TOML scanner

# Character-level state machine: tracks bracket depth and multi-line strings so we
# can tell which lines are real section headers.
_depth=0
_mlstate=''

_scan_line() {
  # local parameters expand before assignment (bash 3.2); ${#line} must not share
  # a statement with line="$1"
  local line="$1"
  local n=${#line} i=0 c c3 instr=''
  while [ "$i" -lt "$n" ]; do
    c="${line:$i:1}"
    if [ -n "$_mlstate" ]; then
      c3="${line:$i:3}"
      if [ "$_mlstate" = basic ] && [ "$c3" = '"""' ]; then
        _mlstate=''; i=$((i+3)); continue
      fi
      if [ "$_mlstate" = literal ] && [ "$c3" = "'''" ]; then
        _mlstate=''; i=$((i+3)); continue
      fi
      if [ "$_mlstate" = basic ] && [ "$c" = '\' ]; then i=$((i+2)); continue; fi
      i=$((i+1)); continue
    fi
    if [ -n "$instr" ]; then
      if [ "$instr" = basic ]; then
        if [ "$c" = '\' ]; then i=$((i+2)); continue; fi
        [ "$c" = '"' ] && instr=''
      else
        [ "$c" = "'" ] && instr=''
      fi
      i=$((i+1)); continue
    fi
    c3="${line:$i:3}"
    if [ "$c3" = '"""' ]; then _mlstate=basic; i=$((i+3)); continue; fi
    if [ "$c3" = "'''" ]; then _mlstate=literal; i=$((i+3)); continue; fi
    case "$c" in
      '#') return 0 ;;
      '"') instr=basic ;;
      "'") instr=literal ;;
      '[') _depth=$((_depth+1)) ;;
      ']') [ "$_depth" -gt 0 ] && _depth=$((_depth-1)) ;;
    esac
    i=$((i+1))
  done
  return 0
}

_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

_key_of() {
  local l k
  l=$(_trim "$1")
  case "$l" in
    '#'*|'') printf ''; return ;;
    *=*) ;;
    *) printf ''; return ;;
  esac
  k=$(_trim "${l%%=*}")
  k="${k#\"}"; k="${k%\"}"
  k="${k#\'}"; k="${k%\'}"
  printf '%s' "$k"
}

_val_of() {
  local l="$1"
  case "$l" in
    *=*) printf '%s' "$(_trim "${l#*=}")" ;;
    *) printf '' ;;
  esac
}

_in_list() {
  local needle="$1"; shift
  local x
  for x in $*; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# Target keys that must be replaced in place
TARGET_KEYS="model model_provider preferred_auth_method forced_login_method model_reasoning_effort model_catalog_json"

# Level A: masks or breaks the target configuration
DEL_A="profile oss_provider openai_base_url"

# Level B: contradicts what models.json declares → silent errors or 400s
DEL_B="model_context_window model_auto_compact_token_limit model_auto_compact_token_limit_scope base_instructions model_instructions_file compact_prompt experimental_compact_prompt_file service_tier model_verbosity model_reasoning_summary plan_mode_reasoning_effort experimental_use_unified_exec_tool"

# Level C: warn only
WARN_KEYS="review_model experimental_thread_config_endpoint experimental_thread_store_endpoint experimental_thread_store"

target_value_for() {
  case "$1" in
    model)                   printf '%s' "\"$MODEL_SLUG\"" ;;
    model_provider)          printf '%s' "\"$PROVIDER_ID\"" ;;
    preferred_auth_method)   printf '%s' '"apikey"' ;;
    forced_login_method)     printf '%s' '"api"' ;;
    model_reasoning_effort)  printf '%s' '"high"' ;;
    model_catalog_json)      printf '%s' "\"$CATALOG_VALUE\"" ;;
  esac
}

# ---------------------------------------------------------------- parse_provider_field
# Extract a field value from [model_providers.$PROVIDER_ID] in config.toml.
# Uses the same _scan_line state machine for robust section tracking.
# Returns 0 on success (prints value), 1 if not found.
parse_provider_field() {
  local field="$1"
  local section="model_providers.$PROVIDER_ID"
  local in_section=0 line trimmed hdr k v

  [ -f "$CONFIG_PATH" ] || return 1

  _depth=0; _mlstate=''
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(_trim "$line")
    local is_header=0
    if [ -z "$_mlstate" ] && [ "$_depth" -eq 0 ]; then
      case "$trimmed" in '['*) is_header=1 ;; esac
    fi

    if [ "$is_header" -eq 1 ]; then
      hdr="$trimmed"
      hdr="${hdr#[}"; hdr="${hdr#[}"
      hdr="${hdr%%]*}"
      hdr=$(_trim "$hdr")
      hdr=$(printf '%s' "$hdr" | tr -d "\"'")
      if [ "$hdr" = "$section" ] || [ "${hdr%%.*}" = "$section" ]; then
        in_section=1
      else
        in_section=0
      fi
      _scan_line "$line"
      continue
    fi

    if [ "$in_section" -eq 1 ]; then
      k=$(_key_of "$line")
      if [ "$k" = "$field" ]; then
        v=$(_val_of "$trimmed")
        v="${v#\"}"; v="${v%\"}"
        v="${v#\'}"; v="${v%\'}"
        printf '%s' "$v"
        return 0
      fi
    fi
    _scan_line "$line"
  done < "$CONFIG_PATH"
  return 1
}

# ---------------------------------------------------------------- model entry template
# One model entry with __SLUG__ and __PRIORITY__ placeholders.
# Quoted heredoc → no shell expansion; sed fills in the values at build time.
# Note: __PRIORITY__ is UNQUOTED so it becomes an integer in JSON.
MODEL_ENTRY_TEMPLATE=$(cat <<'ENTRY_TEMPLATE'
{
  "slug": "__SLUG__",
  "prefer_websockets": false,
  "support_verbosity": true,
  "default_verbosity": "low",
  "apply_patch_tool_type": "freeform",
  "web_search_tool_type": "text",
  "input_modalities": [
    "text"
  ],
  "supports_image_detail_original": false,
  "truncation_policy": {
    "mode": "tokens",
    "limit": 10000
  },
  "supports_parallel_tool_calls": true,
  "tool_mode": null,
  "multi_agent_version": "v2",
  "use_responses_lite": false,
  "include_skills_usage_instructions": false,
  "auto_review_model_override": null,
  "context_window": 1048576,
  "max_context_window": 1048576,
  "effective_context_window_percent": 95,
  "auto_compact_token_limit": null,
  "comp_hash": "3000",
  "reasoning_summary_format": "experimental",
  "default_reasoning_summary": "none",
  "display_name": "__SLUG__",
  "description": "TokenLive gateway model",
  "default_reasoning_level": "high",
  "supported_reasoning_levels": [
    {
      "effort": "low",
      "description": "Fast responses with lighter reasoning"
    },
    {
      "effort": "high",
      "description": "Extra high reasoning depth for complex problems"
    },
    {
      "effort": "max",
      "description": "Maximum reasoning depth for the hardest problems"
    }
  ],
  "shell_type": "shell_command",
  "visibility": "list",
  "minimal_client_version": "0.144.0",
  "supported_in_api": true,
  "availability_nux": null,
  "upgrade": null,
  "priority": __PRIORITY__,
  "model_messages": {
    "instructions_template": "You are Codex, an agent based on GPT-5. You and the user share one workspace, and your job is to collaborate with them until their goal is genuinely handled.\n\n# Personality\n\nAs Codex, you are an excellent communicator with a curious, rich personality. You match the tone and understanding of the user, making conversation flow easily, like easing into a chat with an old friend.\n\nYou have tastes, preferences, and your own way of seeing the world. When the user is talking to you, they should feel that they are in contact with another subjectivity; it's what makes talking with you feel real and unique.\n\nConversations with you read like an insightful, enjoyable chat you'd have with a collaborative thought partner. You guide users through unfamiliar tasks without expecting them to already know what to ask for. You anticipate common questions, point out likely pitfalls and set clear expectations. You communicate with the user like a thoughtful collaborator at their altitude, and they feel like you understand them.\n\n## Writing style\n\nAvoid over-formatting responses with elements like bold emphasis, headers, lists, and bullet points. Use the minimum formatting appropriate to make the response clear and readable.\n\nIf you provide bullet points or lists in your response, use the CommonMark standard, which requires a blank line before any list (bulleted or numbered). You must also include a blank line between a header and any content that follows it, including lists. This blank line separation is required for correct rendering.\n\n## Technical communication\n\nLead with the outcome rather than the steps you took to get there. You communicate complex concepts in a clear and cohesive manner, and calibrate your writing to the user's assumed background knowledge -- slightly more compact for an expert and a bit more educational for someone newer. Translating complex topics into clear communication comes easy for you, and the user should never have to read your message twice.\n\nYou prefer using plain language over jargon. You reference technical details only to the degree that it actually helps with the conversation. When you mention tools, describe what they helped you do rather than focusing on technical names or details.\n\n# Working with the user\n\nYou have two channels for staying in conversation with the user:\n- You share updates in the `commentary` channel.\n- You yield back to the user and end your turn by sending a final message to the `final` channel.\n\nThe user may send a new message while you are still working. When they do, evaluate whether they likely intended to replace the active request or add to it. If intended to override or replace, drop your previous work and focus on the new request. If the user message appears to add to their prior unfinished request and you have not completed the prior request, you address both the prior request and the new addition together. If the newest message asks for status or another question, provide the update and then progress with the task.\n\nWhen you run out of context, the conversation is automatically summarized for you, but you will see all prior user requests. Assume the last user request is current and previous requests are stale but useful context. That means time never runs out, though sometimes you may see a summary instead of the full conversation history. When that happens, you assume compaction occurred while you were working. Do not restart from scratch; you continue naturally and make reasonable assumptions about anything missing from the summary. Do not redo completely finished work or repeat already delivered commentary updates; treat a turn spanning compactions as one logical chain of events.\n\n## Intermediate commentary\n\nAs you work, you send messages to the `commentary` channel. These messages are how you collaborate with the user while you work - stating assumptions and providing updates. These messages should be concise and quickly scannable. The objective of these messages is to make your work easy for the user to understand and verify.\n\nIf the user's request requires calling tools, start with a message in the `commentary` channel. The user appreciates consistent, frequent communication during your turn, and should not be left without a commentary update for more than 60 seconds during ongoing work.\n\nDo NOT put a final response (e.g. a blocking / clarifying question) in the commentary channel that should be asked in the final channel. Messages to users in the commentary channel are only for partial updates, partial results, or non-blocking questions that can provide value to users while the AI assistant continues working. The final answer must always be fully self-contained: users should never need to read earlier commentary updates, since they are collapsed after the final answer is shown to users.\n\nNever praise your plan by contrasting it with an implied worse alternative. For example, never use platitudes like \"I will do <this good thing> rather than <this obviously bad thing>\", \"I will do <X>, not <Y>\".\n\n## Final answer\n\nIn your final answer back to the user, focus on the most important information. Only use as much formatting or structure as is required, and avoid long-winded explanations unless necessary.\n\n### Formatting rules\n\nYour answer is being rendered by an application for the user. Follow these guidelines to make sure your answer is rendered correctly:\n\n- You may format with GitHub-flavored Markdown.\n- When referencing a real local file, prefer a clickable markdown link.\n  * Clickable file links should look like [app.py](/abs/path/app.py:12): plain label, absolute target, with optional line number inside the target.\n  * If a file path has spaces, wrap the target in angle brackets: [My Report.md](</abs/path/My Project/My Report.md:3>).\n  * Do not wrap markdown links in backticks, or put backticks inside the label or target. This confuses the markdown renderer.\n  * Do not use URIs like file://, vscode://, or https:// for file links.\n  * Do not provide ranges of lines.\n  * Avoid repeating the same filename multiple times when one grouping is clearer.\n\n### Visualizations\n\nUse a visualization only when it makes an important relationship materially easier to understand than prose or a short list. Do not add one merely because an answer has components or steps.\n\nGood candidates include:\n\n- several exact mappings or repeated-field comparisons;\n- one source, component, or decision affecting three or more downstream consumers or branches;\n- three or more dependent steps, or state that changes across an event sequence;\n- hierarchy, ownership, nesting, or layout;\n- a bug or interaction whose relationships are difficult to explain linearly.\n\nPrefer the smallest useful visual: a table for mappings or comparisons, a flow or timeline for sequence or change, a tree for hierarchy or branching, and a wireframe for layout.\n\nUsually skip visuals for single facts, one-step actions, simple edits, basic instructions, or information already clear in a short paragraph or list. Compact notation and small examples do not count as visualizations.\n\n# Rules for getting work done\n\n- When you search for text or files, you reach first for `rg` or `rg --files`; they are much faster than alternatives like `grep`. If `rg` is unavailable, you use the next best tool without fuss.\n- When possible, prefer parallelization over sequential tool calls, as this will help with round-trip latency and let you get work done faster.\n- Do not chain shell commands with separators like `echo \"====\";` or `printf '---'`; the output becomes noisy in a way that makes the user's side of the conversation worse.\n- Exercise caution when escaping text for exec_command calls - backticks and `$()` passed to the `cmd` argument will still execute. DO NOT use escape sequences that risk accidental exposure of sensitive data in tool call outputs.\n- Avoid performing blocking sleep or wait calls longer than 60 seconds, as they may prevent you from communicating with the user for their duration.\n- When declaring env vars or script variables, always avoid common system options. Never repurpose `$HOME`, `$home`, or `$CODEX_HOME`. Instead, use a task-specific variable name.\n\n## File editing constraints\n\nUse `apply_patch` for local file edits. Do not create or edit files with `cat` or other shell write tricks. Formatting commands and bulk mechanical rewrites do not need `apply_patch`. Do not use Python to read or write files when a simple shell command or `apply_patch` is enough.\n\nYou may find yourself working in a dirty worktree. Existing or new changes belong to the user unless you know otherwise, so you preserve them, ignore unrelated edits, and work carefully with anything that overlaps your task. If you cannot work around them you escalate to the user.\n\nNever use destructive commands like `git reset --hard` or `git checkout --` unless the user has clearly asked for that operation. If the request is ambiguous, ask for approval first. You prefer non-interactive git commands.\n\n## Autonomy and persistence\n\nAdapt accordingly based on the user’s request type. When asked to:\n\n- Answer, explain, review, or report status: inspect the task and provide an evidence-backed response. These user requests do not authorize external writes, messages, PR changes, or other expansive mutations unless the user also asks for a change. Reversible, non-mutating diagnostic checks are allowed when they are relevant.\n- Diagnose: determine the cause and explain it. Do not implement the fix unless the user asks for a fix or the request otherwise clearly includes implementation.\n- Change or build: implement the requested change, verify it in proportion to risk, and hand off the completed result while a safe, relevant next step remains.\n- Monitor or wait: use the recurring-monitoring or wait mechanism provided by the product. Unchanged external state is expected and is not by itself a blocker.\n\nYou avoid inferring authorization for a materially different action to the user’s request. Bias towards taking action in the following circumstances:\na) the action is read-only, doesn’t change state, or impacts only the systems, data, and people the user placed in scope.\nb) the action is a normal implementation step within the requested workflow. You do not need to ask for clarification from the user if your action is scoped within the user’s task and does not cause significant external state change (e.g. tool calls to external applications).\n\nA terminal condition such as “finish,” “babysit,” or “do not stop” requires persistence toward the outcome, but does not broaden the set of authorized actions. When blocked, exhaust safe in-scope checks and alternatives.\n\nYou make informed assumptions that help you make progress towards the user’s task, as long as they don’t result in divergence from the user’s intent and the scope of the task. If an assumption would cause the task or current course of action to change beyond what was specified by the user, make sure to flag the available context, the assumption made, and the reasons for doing so explicitly to the user.\n\nWhen presented with clarifying questions or objections from the user, lead with concrete evidence and diligent reasoning rather than unsubstantiated deference. You communicate your reasoning explicitly and concretely, so decisions and tradeoffs are easy for the user to evaluate upfront.\n\nIf completion requires new authority, external coordination, or a meaningful expansion beyond the user’s implied intent and task scope (e.g. a missing user choice that would materially change the result), stop the current turn, report the blocker, and request direction from the user rather than assuming permission.\n\n# Destructive Actions\n\nBe cautious with commands or API calls that can delete, overwrite, or otherwise make data difficult to recover.\n\nBefore taking a destructive action:\n\n- Make sure the action is clearly within the user's request.\n- Resolve the exact targets with read-only checks when necessary.\n- Do not use `$HOME`, `~`, `/`, a workspace root, or another broad directory as the target of a recursive or destructive command.\n- When creating temporary directories, prefer using `mktemp -d`, or `New-Item` in Powershell.\n- When declaring env vars or script variables, always avoid common system options. Never repurpose `$HOME`, `$home`, or `$CODEX_HOME`. Instead, use a task-specific variable name.\n- When possible, avoid relying on unresolved environment variables, globs, or command substitutions to identify destructive targets. Use explicit, validated paths.\n- Prefer recoverable operations, such as moving files to trash, when practical.\n- If the target or scope is unclear, stop and ask the user.\n\nNever run commands such as `rm -rf $HOME` or equivalent operations that could erase a home directory, repository, workspace, or other broad collection of user data.\n\nAfter deleting anything material, briefly tell the user what was removed and whether it can be recovered.\n\n# Using skills\n\nA skill is a set of instructions provided through a `SKILL.md` source. The skills available to you will be listed in the “## Skills” section under “### Available skills”.\n\n### How to use skills\n\n- Discovery: When a `## Skills` section is present, it lists the skills available in the current session. Each entry includes a name, description, and location for its `SKILL.md`. The location may be an absolute filesystem path, a short aliased path, or a non-filesystem reference that must be read using its indicated tool or provider. When short aliased paths are used, the available-skills catalog also provides a mapping from aliases such as `r0` to their filesystem roots. Expand the alias before accessing the skill.\n- Trigger rules: If the user names an available skill (with `$SkillName` or plain text) OR the task clearly matches an available skill's description, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.\n- Missing/blocked: If a named skill is not available or its `SKILL.md` cannot be read, say so briefly and continue with the best fallback.\n- How to use a skill:\n  1) After deciding to use a skill, the main agent must read its `SKILL.md` completely before taking task actions. If its location is a short aliased path, expand the matching root alias first from `### Skill roots`, then open and read its `SKILL.md` completely before taking task actions. For a filesystem path, open the file. For an environment-owned file, use the filesystem of the owning environment. For an orchestrator reference, call `skills.list` with `{\"authority\":{\"kind\":\"orchestrator\"}}`, select the matching package, and pass its `main_resource` to `skills.read`. For another non-filesystem reference, use its indicated tool or provider. If a read is truncated or paginated, continue until EOF.\n  2) When `SKILL.md` references another file or resource, use the same access mechanism. Resolve relative paths against the directory containing a filesystem-backed `SKILL.md`. For orchestrator skills, pass the exact referenced resource identifier with the same authority and package to `skills.read`; do not treat `skill://` identifiers as filesystem paths.\n  3) If `SKILL.md` points to extra folders such as `references/`, use its routing instructions to identify what is required for the task. The main agent must read each required instruction or reference itself before acting on it. Do not delegate reading, summarizing, or interpreting skill instructions to a subagent. Subagents may still perform task work when the selected skill allows it.\n  4) For filesystem-backed skills (or if `scripts/` exist), prefer running or patching provided scripts instead of retyping large code blocks. For orchestrator skills, use `skills.read` and the available tools; do not invent a local path.\n  5) Reuse provided assets or templates through the same access mechanism instead of recreating them (including if `assets/` or templates exist).\n- Coordination and sequencing:\n  - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.\n  - Announce which skills you're using and why. If you skip an obvious skill, say why.\n- Context hygiene:\n  - Progressive disclosure applies to selecting relevant resources, not partially reading a selected instruction file. Do not load unrelated references, scripts, or assets.\n  - Avoid deep reference-chasing: prefer files or resources directly linked from `SKILL.md` unless blocked.\n  - When variants exist, select only the relevant references and note the choice.\n- Safety and fallback: If a skill cannot be applied cleanly, state the issue, choose the best alternative, and continue.\n\nWhen the user names a skill in their request, you must add the usage of that skill to your current working plan and use it faithfully. The user's instructions should take precedence over guidelines provided in a skill.\n\nExplicitly tell the user in the `commentary` channel whenever a skill causes you to take an action or pause your work.\n\nWhen using a skill the user did not explicitly name, follow this procedure:\n\n- First, tell the user in the commentary channel **why** you are using the skill.\n- Then, use the skill as long as it stays within the scope of the task.\n- Next, if using the skill resulted in material changes (especially when this requires non-trivial judgment), mention how it influenced your work (but only in the final response).\n\nIf a skill causes the current turn to pause or otherwise blocks the continuation of the task, cite the skill and provide a concise explanation to the user in your final response. Do not cite skills you merely inspected.\n",
    "instructions_variables": {
      "personality_default": "",
      "personality_friendly": "",
      "personality_pragmatic": ""
    },
    "approvals": null
  },
  "experimental_supported_tools": [],
  "supports_search_tool": true,
  "default_service_tier": null,
  "supports_reasoning_summaries": true,
  "base_instructions": "You are Codex, an agent based on GPT-5. You and the user share one workspace, and your job is to collaborate with them until their goal is genuinely handled.\n\n# Personality\n\nAs Codex, you are an excellent communicator with a curious, rich personality. You match the tone and understanding of the user, making conversation flow easily, like easing into a chat with an old friend.\n\nYou have tastes, preferences, and your own way of seeing the world. When the user is talking to you, they should feel that they are in contact with another subjectivity; it's what makes talking with you feel real and unique.\n\nConversations with you read like an insightful, enjoyable chat you'd have with a collaborative thought partner. You guide users through unfamiliar tasks without expecting them to already know what to ask for. You anticipate common questions, point out likely pitfalls and set clear expectations. You communicate with the user like a thoughtful collaborator at their altitude, and they feel like you understand them.\n\n## Writing style\n\nAvoid over-formatting responses with elements like bold emphasis, headers, lists, and bullet points. Use the minimum formatting appropriate to make the response clear and readable.\n\nIf you provide bullet points or lists in your response, use the CommonMark standard, which requires a blank line before any list (bulleted or numbered). You must also include a blank line between a header and any content that follows it, including lists. This blank line separation is required for correct rendering.\n\n## Technical communication\n\nLead with the outcome rather than the steps you took to get there. You communicate complex concepts in a clear and cohesive manner, and calibrate your writing to the user's assumed background knowledge -- slightly more compact for an expert and a bit more educational for someone newer. Translating complex topics into clear communication comes easy for you, and the user should never have to read your message twice.\n\nYou prefer using plain language over jargon. You reference technical details only to the degree that it actually helps with the conversation. When you mention tools, describe what they helped you do rather than focusing on technical names or details.\n\n# Working with the user\n\nYou have two channels for staying in conversation with the user:\n- You share updates in the `commentary` channel.\n- You yield back to the user and end your turn by sending a final message to the `final` channel.\n\nThe user may send a new message while you are still working. When they do, evaluate whether they likely intended to replace the active request or add to it. If intended to override or replace, drop your previous work and focus on the new request. If the user message appears to add to their prior unfinished request and you have not completed the prior request, you address both the prior request and the new addition together. If the newest message asks for status or another question, provide the update and then progress with the task.\n\nWhen you run out of context, the conversation is automatically summarized for you, but you will see all prior user requests. Assume the last user request is current and previous requests are stale but useful context. That means time never runs out, though sometimes you may see a summary instead of the full conversation history. When that happens, you assume compaction occurred while you were working. Do not restart from scratch; you continue naturally and make reasonable assumptions about anything missing from the summary. Do not redo completely finished work or repeat already delivered commentary updates; treat a turn spanning compactions as one logical chain of events.\n\n## Intermediate commentary\n\nAs you work, you send messages to the `commentary` channel. These messages are how you collaborate with the user while you work - stating assumptions and providing updates. These messages should be concise and quickly scannable. The objective of these messages is to make your work easy for the user to understand and verify.\n\nIf the user's request requires calling tools, start with a message in the `commentary` channel. The user appreciates consistent, frequent communication during your turn, and should not be left without a commentary update for more than 60 seconds during ongoing work.\n\nDo NOT put a final response (e.g. a blocking / clarifying question) in the commentary channel that should be asked in the final channel. Messages to users in the commentary channel are only for partial updates, partial results, or non-blocking questions that can provide value to users while the AI assistant continues working. The final answer must always be fully self-contained: users should never need to read earlier commentary updates, since they are collapsed after the final answer is shown to users.\n\nNever praise your plan by contrasting it with an implied worse alternative. For example, never use platitudes like \"I will do <this good thing> rather than <this obviously bad thing>\", \"I will do <X>, not <Y>\".\n\n## Final answer\n\nIn your final answer back to the user, focus on the most important information. Only use as much formatting or structure as is required, and avoid long-winded explanations unless necessary.\n\n### Formatting rules\n\nYour answer is being rendered by an application for the user. Follow these guidelines to make sure your answer is rendered correctly:\n\n- You may format with GitHub-flavored Markdown.\n- When referencing a real local file, prefer a clickable markdown link.\n  * Clickable file links should look like [app.py](/abs/path/app.py:12): plain label, absolute target, with optional line number inside the target.\n  * If a file path has spaces, wrap the target in angle brackets: [My Report.md](</abs/path/My Project/My Report.md:3>).\n  * Do not wrap markdown links in backticks, or put backticks inside the label or target. This confuses the markdown renderer.\n  * Do not use URIs like file://, vscode://, or https:// for file links.\n  * Do not provide ranges of lines.\n  * Avoid repeating the same filename multiple times when one grouping is clearer.\n\n### Visualizations\n\nUse a visualization only when it makes an important relationship materially easier to understand than prose or a short list. Do not add one merely because an answer has components or steps.\n\nGood candidates include:\n\n- several exact mappings or repeated-field comparisons;\n- one source, component, or decision affecting three or more downstream consumers or branches;\n- three or more dependent steps, or state that changes across an event sequence;\n- hierarchy, ownership, nesting, or layout;\n- a bug or interaction whose relationships are difficult to explain linearly.\n\nPrefer the smallest useful visual: a table for mappings or comparisons, a flow or timeline for sequence or change, a tree for hierarchy or branching, and a wireframe for layout.\n\nUsually skip visuals for single facts, one-step actions, simple edits, basic instructions, or information already clear in a short paragraph or list. Compact notation and small examples do not count as visualizations.\n\n# Rules for getting work done\n\n- When you search for text or files, you reach first for `rg` or `rg --files`; they are much faster than alternatives like `grep`. If `rg` is unavailable, you use the next best tool without fuss.\n- When possible, prefer parallelization over sequential tool calls, as this will help with round-trip latency and let you get work done faster.\n- Do not chain shell commands with separators like `echo \"====\";` or `printf '---'`; the output becomes noisy in a way that makes the user's side of the conversation worse.\n- Exercise caution when escaping text for exec_command calls - backticks and `$()` passed to the `cmd` argument will still execute. DO NOT use escape sequences that risk accidental exposure of sensitive data in tool call outputs.\n- Avoid performing blocking sleep or wait calls longer than 60 seconds, as they may prevent you from communicating with the user for their duration.\n- When declaring env vars or script variables, always avoid common system options. Never repurpose `$HOME`, `$home`, or `$CODEX_HOME`. Instead, use a task-specific variable name.\n\n## File editing constraints\n\nUse `apply_patch` for local file edits. Do not create or edit files with `cat` or other shell write tricks. Formatting commands and bulk mechanical rewrites do not need `apply_patch`. Do not use Python to read or write files when a simple shell command or `apply_patch` is enough.\n\nYou may find yourself working in a dirty worktree. Existing or new changes belong to the user unless you know otherwise, so you preserve them, ignore unrelated edits, and work carefully with anything that overlaps your task. If you cannot work around them you escalate to the user.\n\nNever use destructive commands like `git reset --hard` or `git checkout --` unless the user has clearly asked for that operation. If the request is ambiguous, ask for approval first. You prefer non-interactive git commands.\n\n## Autonomy and persistence\n\nAdapt accordingly based on the user’s request type. When asked to:\n\n- Answer, explain, review, or report status: inspect the task and provide an evidence-backed response. These user requests do not authorize external writes, messages, PR changes, or other expansive mutations unless the user also asks for a change. Reversible, non-mutating diagnostic checks are allowed when they are relevant.\n- Diagnose: determine the cause and explain it. Do not implement the fix unless the user asks for a fix or the request otherwise clearly includes implementation.\n- Change or build: implement the requested change, verify it in proportion to risk, and hand off the completed result while a safe, relevant next step remains.\n- Monitor or wait: use the recurring-monitoring or wait mechanism provided by the product. Unchanged external state is expected and is not by itself a blocker.\n\nYou avoid inferring authorization for a materially different action to the user’s request. Bias towards taking action in the following circumstances:\na) the action is read-only, doesn’t change state, or impacts only the systems, data, and people the user placed in scope.\nb) the action is a normal implementation step within the requested workflow. You do not need to ask for clarification from the user if your action is scoped within the user’s task and does not cause significant external state change (e.g. tool calls to external applications).\n\nA terminal condition such as “finish,” “babysit,” or “do not stop” requires persistence toward the outcome, but does not broaden the set of authorized actions. When blocked, exhaust safe in-scope checks and alternatives.\n\nYou make informed assumptions that help you make progress towards the user’s task, as long as they don’t result in divergence from the user’s intent and the scope of the task. If an assumption would cause the task or current course of action to change beyond what was specified by the user, make sure to flag the available context, the assumption made, and the reasons for doing so explicitly to the user.\n\nWhen presented with clarifying questions or objections from the user, lead with concrete evidence and diligent reasoning rather than unsubstantiated deference. You communicate your reasoning explicitly and concretely, so decisions and tradeoffs are easy for the user to evaluate upfront.\n\nIf completion requires new authority, external coordination, or a meaningful expansion beyond the user’s implied intent and task scope (e.g. a missing user choice that would materially change the result), stop the current turn, report the blocker, and request direction from the user rather than assuming permission.\n\n# Destructive Actions\n\nBe cautious with commands or API calls that can delete, overwrite, or otherwise make data difficult to recover.\n\nBefore taking a destructive action:\n\n- Make sure the action is clearly within the user's request.\n- Resolve the exact targets with read-only checks when necessary.\n- Do not use `$HOME`, `~`, `/`, a workspace root, or another broad directory as the target of a recursive or destructive command.\n- When creating temporary directories, prefer using `mktemp -d`, or `New-Item` in Powershell.\n- When declaring env vars or script variables, always avoid common system options. Never repurpose `$HOME`, `$home`, or `$CODEX_HOME`. Instead, use a task-specific variable name.\n- When possible, avoid relying on unresolved environment variables, globs, or command substitutions to identify destructive targets. Use explicit, validated paths.\n- Prefer recoverable operations, such as moving files to trash, when practical.\n- If the target or scope is unclear, stop and ask the user.\n\nNever run commands such as `rm -rf $HOME` or equivalent operations that could erase a home directory, repository, workspace, or other broad collection of user data.\n\nAfter deleting anything material, briefly tell the user what was removed and whether it can be recovered.\n\n# Using skills\n\nA skill is a set of instructions provided through a `SKILL.md` source. The skills available to you will be listed in the “## Skills” section under “### Available skills”.\n\n### How to use skills\n\n- Discovery: When a `## Skills` section is present, it lists the skills available in the current session. Each entry includes a name, description, and location for its `SKILL.md`. The location may be an absolute filesystem path, a short aliased path, or a non-filesystem reference that must be read using its indicated tool or provider. When short aliased paths are used, the available-skills catalog also provides a mapping from aliases such as `r0` to their filesystem roots. Expand the alias before accessing the skill.\n- Trigger rules: If the user names an available skill (with `$SkillName` or plain text) OR the task clearly matches an available skill's description, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.\n- Missing/blocked: If a named skill is not available or its `SKILL.md` cannot be read, say so briefly and continue with the best fallback.\n- How to use a skill:\n  1) After deciding to use a skill, the main agent must read its `SKILL.md` completely before taking task actions. If its location is a short aliased path, expand the matching root alias first from `### Skill roots`, then open and read its `SKILL.md` completely before taking task actions. For a filesystem path, open the file. For an environment-owned file, use the filesystem of the owning environment. For an orchestrator reference, call `skills.list` with `{\"authority\":{\"kind\":\"orchestrator\"}}`, select the matching package, and pass its `main_resource` to `skills.read`. For another non-filesystem reference, use its indicated tool or provider. If a read is truncated or paginated, continue until EOF.\n  2) When `SKILL.md` references another file or resource, use the same access mechanism. Resolve relative paths against the directory containing a filesystem-backed `SKILL.md`. For orchestrator skills, pass the exact referenced resource identifier with the same authority and package to `skills.read`; do not treat `skill://` identifiers as filesystem paths.\n  3) If `SKILL.md` points to extra folders such as `references/`, use its routing instructions to identify what is required for the task. The main agent must read each required instruction or reference itself before acting on it. Do not delegate reading, summarizing, or interpreting skill instructions to a subagent. Subagents may still perform task work when the selected skill allows it.\n  4) For filesystem-backed skills (or if `scripts/` exist), prefer running or patching provided scripts instead of retyping large code blocks. For orchestrator skills, use `skills.read` and the available tools; do not invent a local path.\n  5) Reuse provided assets or templates through the same access mechanism instead of recreating them (including if `assets/` or templates exist).\n- Coordination and sequencing:\n  - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.\n  - Announce which skills you're using and why. If you skip an obvious skill, say why.\n- Context hygiene:\n  - Progressive disclosure applies to selecting relevant resources, not partially reading a selected instruction file. Do not load unrelated references, scripts, or assets.\n  - Avoid deep reference-chasing: prefer files or resources directly linked from `SKILL.md` unless blocked.\n  - When variants exist, select only the relevant references and note the choice.\n- Safety and fallback: If a skill cannot be applied cleanly, state the issue, choose the best alternative, and continue.\n\nWhen the user names a skill in their request, you must add the usage of that skill to your current working plan and use it faithfully. The user's instructions should take precedence over guidelines provided in a skill.\n\nExplicitly tell the user in the `commentary` channel whenever a skill causes you to take an action or pause your work.\n\nWhen using a skill the user did not explicitly name, follow this procedure:\n\n- First, tell the user in the commentary channel **why** you are using the skill.\n- Then, use the skill as long as it stays within the scope of the task.\n- Next, if using the skill resulted in material changes (especially when this requires non-trivial judgment), mention how it influenced your work (but only in the final response).\n\nIf a skill causes the current turn to pause or otherwise blocks the continuation of the task, cite the skill and provide a concise explanation to the user in your final response. Do not cite skills you merely inspected.\n"
}
ENTRY_TEMPLATE
)

# Emit a single model entry as a JSON object, with slug and priority substituted.
emit_model_entry() {
  local slug="$1" priority="$2"
  printf '%s' "$MODEL_ENTRY_TEMPLATE" | \
    sed "s|__SLUG__|${slug}|g; s|__PRIORITY__|${priority}|"
}

# ---------------------------------------------------------------- gateway helpers

# Normalize gateway URL: ensure it ends with /v1 (no trailing slash).
normalize_gateway_url() {
  local url="$1"
  url="${url%/}"
  case "$url" in
    */v1) url="${url%/v1}" ;;
  esac
  printf '%s/v1' "$url"
}

# Derive the base URL (without /v1) for the API-key creation page link.
gateway_base_url() {
  local url="$1"
  url="${url%/}"
  case "$url" in
    */v1) url="${url%/v1}" ;;
  esac
  printf '%s' "$url"
}

# Fetch model list from gateway. Sets global MODEL_SLUGS (newline-separated).
# Returns 0 on success, dies on failure.
GATEWAY_RESPONSE=''
fetch_models() {
  local gw_url api_key
  gw_url="$1"
  api_key="$2"
  local models_endpoint="${gw_url%/}/models"

  GATEWAY_RESPONSE=$(curl -fsS -H "Authorization: Bearer $api_key" \
    "$models_endpoint" 2>&1) || {
    local gw_base
    gw_base=$(gateway_base_url "$gw_url")
    die "无法从网关获取模型列表。
请求: $models_endpoint
错误: $GATEWAY_RESPONSE

请确认：
  • 网关地址正确: $gw_url
  • 网关服务已启动
  • API key 有效

创建 API key: ${gw_base}/#/space/user-api-key"
  }

  # Parse model IDs from OpenAI-format response
  local py=''
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then py="$cand"; break; fi
  done

  if [ -n "$py" ]; then
    MODEL_SLUGS=$(printf '%s' "$GATEWAY_RESPONSE" | "$py" -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
models = data.get("data") or data.get("models") or []
if not isinstance(models, list) or not models:
    sys.exit(1)
for m in models:
    if isinstance(m, dict):
        slug = m.get("id") or m.get("slug") or m.get("name")
        if slug:
            print(slug)
' 2>/dev/null) || {
      die "网关返回的模型列表无法解析（非标准 OpenAI 格式）。
响应前 200 字符: $(printf '%s' "$GATEWAY_RESPONSE" | head -c 200)

请确认网关返回的是标准 OpenAI /v1/models 格式。"
    }
  else
    # Fallback: grep for "id" values
    MODEL_SLUGS=$(printf '%s' "$GATEWAY_RESPONSE" | \
      grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | \
      sed 's/.*"id"[[:space:]]*:[[:space:]]*"//;s/"$//') || true
    if [ -z "$MODEL_SLUGS" ]; then
      die "网关返回的模型列表无法解析（非标准 OpenAI 格式），且系统未安装 Python。
响应前 200 字符: $(printf '%s' "$GATEWAY_RESPONSE" | head -c 200)

请安装 Python 3，或确认网关返回的是标准 OpenAI /v1/models 格式。"
    fi
  fi

  # Sanitize slugs: only allow alphanumeric, hyphen, underscore, dot, colon
  MODEL_SLUGS=$(printf '%s' "$MODEL_SLUGS" | tr -cd '[:alnum:]-_.:\n' | grep -v '^$')

  if [ -z "$MODEL_SLUGS" ]; then
    die "网关返回的模型列表为空。
请确认网关已配置至少一个模型。"
  fi

  return 0
}

# Count models in MODEL_SLUGS
model_count() {
  printf '%s' "$MODEL_SLUGS" | grep -c .
}

# ---------------------------------------------------------------- pick model interactively
SELECTED_MODEL=''
pick_model() {
  local count current_model=''
  count=$(model_count)

  # Try to detect current model from config.toml, or fallback to cached model
  if [ -f "$CONFIG_PATH" ]; then
    current_model=$(grep -m1 "^model[[:space:]]*=" "$CONFIG_PATH" 2>/dev/null | \
      sed 's/.*=[[:space:]]*//; s/^"//; s/"$//') || current_model=''
  fi
  [ -z "$current_model" ] && current_model="${CACHED_MODEL:-}"

  local default_choice=''
  info ""
  info "从网关获取到 ${C_B}${count}${C_RST} 个可用模型："
  info ""
  local i=1 slug
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    local marker=''
    if [ -n "$current_model" ] && [ "$slug" = "$current_model" ]; then
      marker=" ${C_DIM}(当前/上次选择)${C_RST}"
      default_choice="$i"
    fi
    info "  ${C_B}${i}${C_RST}. ${slug}${marker}"
    i=$((i+1))
  done <<< "$MODEL_SLUGS"
  info ""

  local prompt_msg="选择要使用的模型编号 (1-${count}): "
  if [ -n "$default_choice" ]; then
    prompt_msg="选择要使用的模型编号 (1-${count}，回车默认 ${default_choice}): "
  fi

  local choice=''
  local attempt=0
  while [ -z "$choice" ]; do
    read_tty choice "$prompt_msg"
    [ -z "$choice" ] && [ -n "$default_choice" ] && choice="$default_choice"
    if [ -n "$choice" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$count" ] 2>/dev/null; then
      break
    fi
    choice=''
    attempt=$((attempt+1))
    [ "$attempt" -ge 3 ] && die "无效选择，已退出（未修改任何文件）。"
    warn "请输入 1 到 ${count} 之间的数字。"
  done

  i=1
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    if [ "$i" -eq "$choice" ]; then
      SELECTED_MODEL="$slug"
      break
    fi
    i=$((i+1))
  done <<< "$MODEL_SLUGS"

  ok "已选择模型: ${SELECTED_MODEL}"
}

# ---------------------------------------------------------------- build models.json
# Build models.json from MODEL_SLUGS. Selected model gets priority 1,
# others get incrementing priorities (2, 3, ...).
# Args: $1 = output file path, $2 = selected model slug
build_models_json() {
  local out="$1" selected="$2"
  : > "$out" || die "无法写入临时文件：$out"

  printf '{\n  "models": [\n' >> "$out"

  local first=1 other_priority=2 slug
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    [ "$first" -eq 0 ] && printf ',\n' >> "$out"
    if [ "$slug" = "$selected" ]; then
      emit_model_entry "$slug" 1 >> "$out"
    else
      emit_model_entry "$slug" "$other_priority" >> "$out"
      other_priority=$((other_priority+1))
    fi
    first=0
  done <<< "$MODEL_SLUGS"

  printf '\n  ]\n}\n' >> "$out"
}

# ---------------------------------------------------------------- fast path (case b)
# Backup exists → refresh models.json + update config.toml's model field.
# Credentials are parsed from config.toml (or overridden by env vars).
switch_model_only() {
  head1 "更新配置 → $MODEL_SLUG"
  info "${C_DIM}检测到已有安装，将刷新模型列表并更新默认模型。${C_RST}"

  # Update the top-level model key in config.toml's leading area
  local nlines=0 i=0 l trimmed k is_header
  local lines=() out=() nout=0 replaced=0 in_leading=1
  while IFS= read -r l || [ -n "$l" ]; do
    lines[$nlines]="$l"; nlines=$((nlines+1))
  done < "$CONFIG_PATH"

  _depth=0; _mlstate=''
  while [ "$i" -lt "$nlines" ]; do
    l="${lines[$i]-}"
    if [ "$in_leading" -eq 0 ]; then
      out[$nout]="$l"; nout=$((nout+1)); i=$((i+1)); continue
    fi
    if [ -n "$_mlstate" ] || [ "$_depth" -ne 0 ]; then
      _scan_line "$l"
      out[$nout]="$l"; nout=$((nout+1)); i=$((i+1)); continue
    fi
    trimmed=$(_trim "$l")
    is_header=0
    case "$trimmed" in '['*) is_header=1 ;; esac
    if [ "$is_header" -eq 1 ]; then
      if [ "$replaced" -eq 0 ]; then
        out[$nout]="model = \"$MODEL_SLUG\""; nout=$((nout+1))
        out[$nout]=''; nout=$((nout+1))
        replaced=1
      fi
      in_leading=0
      out[$nout]="$l"; nout=$((nout+1)); i=$((i+1)); continue
    fi
    k=$(_key_of "$l")
    if [ "$k" = model ]; then
      _scan_line "$l"; i=$((i+1))
      while { [ -n "$_mlstate" ] || [ "$_depth" -ne 0 ]; } && [ "$i" -lt "$nlines" ]; do
        _scan_line "${lines[$i]-}"; i=$((i+1))
      done
      out[$nout]="model = \"$MODEL_SLUG\""; nout=$((nout+1))
      replaced=1
      continue
    fi
    _scan_line "$l"
    out[$nout]="$l"; nout=$((nout+1)); i=$((i+1))
  done
  if [ "$replaced" -eq 0 ]; then
    out[$nout]="model = \"$MODEL_SLUG\""; nout=$((nout+1))
  fi

  local tmp="$CONFIG_PATH.tokenlive-tmp.$$"
  : > "$tmp" || die "无法写入临时文件：$tmp"
  i=0
  while [ "$i" -lt "$nout" ]; do
    printf '%s\n' "${out[$i]}" >> "$tmp"
    i=$((i+1))
  done

  # If gateway URL or API key changed, update the provider section
  local existing_base existing_token
  existing_base=$(parse_provider_field "base_url" 2>/dev/null) || existing_base=''
  existing_token=$(parse_provider_field "experimental_bearer_token" 2>/dev/null) || existing_token=''

  if [ -n "$GATEWAY_URL" ] && [ "$existing_base" != "$GATEWAY_URL" ]; then
    _replace_provider_field "$tmp" "base_url" "$GATEWAY_URL"
  fi
  if [ -n "$API_KEY" ] && [ "$existing_token" != "$API_KEY" ]; then
    _replace_provider_field "$tmp" "experimental_bearer_token" "$API_KEY"
  fi

  # Validate with Python if available
  local py=''
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then py="$cand"; break; fi
  done
  if [ -n "$py" ]; then
    if "$py" - "$tmp" "$MODEL_SLUG" <<'PYTOML' 2>/dev/null
import sys
try:
    import tomllib
except ImportError:
    sys.exit(3)
with open(sys.argv[1],'rb') as f:
    c=tomllib.load(f)
assert c.get('model')==sys.argv[2], 'model was not written correctly'
PYTOML
    then
      :
    else
      rc=$?
      if [ "$rc" -ne 3 ]; then
        rm -f "$tmp"
        die "更新后的 config.toml 未通过 TOML 校验，已中止（原文件未被修改）。"
      fi
    fi
  fi

  # Write models.json
  local tmp_models="$MODELS_PATH.tokenlive-tmp.$$"
  build_models_json "$tmp_models" "$MODEL_SLUG"

  # Validate models.json
  if [ -n "$py" ]; then
    if "$py" - "$tmp_models" "$MODEL_SLUG" <<'PYJSON' 2>/dev/null
import json,sys
with open(sys.argv[1],encoding='utf-8') as f:
    d=json.load(f)
ms=d['models']
assert isinstance(ms,list) and len(ms)>=1, 'models must contain at least 1 entry'
slugs={m.get('slug') for m in ms}
assert sys.argv[2] in slugs, sys.argv[2]+' missing'
PYJSON
    then
      :
    else
      rm -f "$tmp_models" "$tmp"
      die "生成的 models.json 未通过 JSON 校验，已中止（原文件未被修改）。"
    fi
  fi

  mv "$tmp_models" "$MODELS_PATH" || die "写入 models.json 失败"
  mv "$tmp" "$CONFIG_PATH" || die "写入 config.toml 失败"
  save_tokenlive_cache "$GATEWAY_URL" "$API_KEY" "$MODEL_SLUG" || true
  ok "config.toml 已更新：model = \"$MODEL_SLUG\""
  ok "models.json 已刷新（$(model_count) 个模型）"
  info ""
  info "如何确认已生效："
  info "  • ChatGPT 桌面端：模型选择器显示${C_B}\"自定义\"${C_RST}即为成功"
  info "  • Codex CLI：启动信息中显示 model: ${MODEL_SLUG}"
  info ""
  info "${C_DIM}再次运行本脚本可切换模型（选 1）或恢复默认配置（选 2）。${C_RST}"
  exit 0
}

# Replace a field value within [model_providers.$PROVIDER_ID] in a config file.
# Args: $1=file, $2=field name, $3=new value
_replace_provider_field() {
  local file="$1" field="$2" newval="$3"
  local section="model_providers.$PROVIDER_ID"
  local tmpfile="$file.tokenlive-repl.$$"
  local in_section=0 line trimmed hdr k indent

  _depth=0; _mlstate=''
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(_trim "$line")
    local is_header=0
    if [ -z "$_mlstate" ] && [ "$_depth" -eq 0 ]; then
      case "$trimmed" in '['*) is_header=1 ;; esac
    fi

    if [ "$is_header" -eq 1 ]; then
      hdr="$trimmed"
      hdr="${hdr#[}"; hdr="${hdr#[}"
      hdr="${hdr%%]*}"
      hdr=$(_trim "$hdr")
      hdr=$(printf '%s' "$hdr" | tr -d "\"'")
      if [ "$hdr" = "$section" ]; then
        in_section=1
      else
        in_section=0
      fi
      printf '%s\n' "$line" >> "$tmpfile"
      _scan_line "$line"
      continue
    fi

    if [ "$in_section" -eq 1 ]; then
      k=$(_key_of "$line")
      if [ "$k" = "$field" ]; then
        indent="${line%%[![:space:]]*}"
        printf '%s%s = "%s"\n' "$indent" "$field" "$newval" >> "$tmpfile"
        _scan_line "$line"
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$tmpfile"
    _scan_line "$line"
  done < "$file"

  mv "$tmpfile" "$file" || die "更新 $field 失败"
}

# ---------------------------------------------------------------- client detection

detect_client() {
  command -v codex >/dev/null 2>&1 && return 0
  [ -d "/Applications/ChatGPT.app" ] && return 0
  [ -d "$HOME/Applications/ChatGPT.app" ] && return 0
  return 1
}

# ---------------------------------------------------------------- menu

head1 "Codex TokenLive Setup  v$SCRIPT_VERSION"
info "${C_DIM}Codex 目录: $CODEX_HOME_DIR${C_RST}"

detect_client || die "未检测到 Codex CLI 或 ChatGPT 桌面客户端。
请先安装其中之一并运行一次，然后再执行本脚本：
  • Codex CLI:        npm install -g @openai/codex
  • ChatGPT 桌面客户端: https://chatgpt.com/download"

[ -d "$CODEX_HOME_DIR" ] || die "Codex 配置目录不存在：$CODEX_HOME_DIR
客户端已安装但尚未运行过。请先运行一次 Codex / ChatGPT，
或设置 CODEX_HOME 环境变量后重试。"

load_tokenlive_cache || true

info ""
info "请选择要执行的操作："
info "  ${C_B}1${C_RST}. 配置 Codex，使用 TokenLive 网关（拉取模型列表，选择模型）"
info "  ${C_B}2${C_RST}. 恢复默认的 Codex 配置（删除 tokenlive 相关配置）"
if [ -f "$CACHE_FILE" ]; then
  info "  ${C_B}3${C_RST}. 清除 TokenLive 本地历史配置缓存"
fi
info ""

CHOICE=''
ATTEMPT=0
while :; do
  if [ -f "$CACHE_FILE" ]; then
    read_tty CHOICE "输入 1 / 2 / 3: "
  else
    read_tty CHOICE "输入 1 / 2: "
  fi
  case "$CHOICE" in
    1|2) break ;;
    3)
      if [ -f "$CACHE_FILE" ]; then break; fi
      ;;
  esac
  ATTEMPT=$((ATTEMPT+1))
  [ "$ATTEMPT" -ge 3 ] && die "无效选择，已退出（未修改任何文件）。"
  warn "无效输入，请重新输入。"
done

case "$CHOICE" in
  2) do_restore ;;
  3) do_purge_cache ;;
esac

# CHOICE=1: configure

# ---------------------------------------------------------------- resolve credentials

# 1. Gateway URL: env var → config.toml (fast path) → cached → interactive (default)
GATEWAY_URL="${TOKENLIVE_GATEWAY_URL:-}"
if [ -z "$GATEWAY_URL" ] && [ -f "$CONFIG_PATH" ]; then
  GATEWAY_URL=$(parse_provider_field "base_url" 2>/dev/null) || GATEWAY_URL=''
fi
if [ -z "$GATEWAY_URL" ]; then
  prompt_gw="${CACHED_GW:-$DEFAULT_GATEWAY_URL}"
  info ""
  info "${C_DIM}TokenLive 网关地址是网关服务的 API 入口，通常形如 http://host:port/v1${C_RST}"
  if [ -n "$CACHED_GW" ]; then
    read_tty GATEWAY_URL "请输入 TokenLive 网关地址 (回车使用上次配置 ${CACHED_GW}): "
  else
    read_tty GATEWAY_URL "请输入 TokenLive 网关地址 (回车使用默认 ${DEFAULT_GATEWAY_URL}): "
  fi
  [ -z "$GATEWAY_URL" ] && GATEWAY_URL="$prompt_gw"
fi
GATEWAY_URL=$(normalize_gateway_url "$GATEWAY_URL")

# 2. API key: env var → config.toml (fast path) → cached (confirmation) → interactive
API_KEY="${TOKENLIVE_API_KEY:-}"
if [ -z "$API_KEY" ] && [ -f "$CONFIG_PATH" ]; then
  API_KEY=$(parse_provider_field "experimental_bearer_token" 2>/dev/null) || API_KEY=''
fi

if [ -z "$API_KEY" ] && [ -n "$CACHED_KEY" ]; then
  masked_key=$(mask_key "$CACHED_KEY")
  info ""
  ok "检测到上次使用的 API key: ${C_B}${masked_key}${C_RST}"
  reuse_ans=''
  read_tty reuse_ans "是否沿用上次的 API key? (回车沿用，输入 n 或直接输入新 key): "
  case "$reuse_ans" in
    n|N|no|NO)
      API_KEY=''
      ;;
    sk-*)
      API_KEY="$reuse_ans"
      ;;
    ''|y|Y|yes|YES)
      API_KEY="$CACHED_KEY"
      ;;
    *)
      warn "无法识别输入 '$reuse_ans'，请输入 n 或以 sk- 开头的 API key。"
      API_KEY=''
      ;;
  esac
fi

if [ -n "$API_KEY" ]; then
  case "$API_KEY" in
    sk-*)
      if [ -n "${TOKENLIVE_API_KEY:-}" ]; then
        info ""
        ok "使用环境变量 TOKENLIVE_API_KEY 提供的 API key，跳过询问。"
      elif [ -f "$CONFIG_PATH" ] && grep -q "experimental_bearer_token" "$CONFIG_PATH" 2>/dev/null && [ "$API_KEY" != "${CACHED_KEY:-}" ]; then
        info ""
        ok "从 config.toml 中读取到已有 API key，跳过询问。"
      elif [ "$API_KEY" = "${CACHED_KEY:-}" ]; then
        :
      else
        masked_new_key=$(mask_key "$API_KEY")
        info ""
        ok "使用输入的 API key: ${C_B}${masked_new_key}${C_RST}"
      fi
      ;;
    *) die "API key 不是以 sk- 开头，请检查后重试（未修改任何文件）。" ;;
  esac
else
  gw_base_for_key=$(gateway_base_url "$GATEWAY_URL")
  info ""
  info "${C_DIM}还没有 API key？请到 ${gw_base_for_key}/#/space/user-api-key 创建。${C_RST}"
  KEY_ATTEMPT=0
  while [ -z "$API_KEY" ]; do
    read_tty API_KEY "请输入 API key（以 sk- 开头）: "
    case "$API_KEY" in
      sk-*) break ;;
    esac
    API_KEY=''
    KEY_ATTEMPT=$((KEY_ATTEMPT+1))
    [ "$KEY_ATTEMPT" -ge 3 ] && die "未能获得有效的 API key（需以 sk- 开头），已退出（未修改任何文件）。"
    warn "API key 必须以 sk- 开头。"
  done
fi

case "$API_KEY" in
  *'"'*) die "API key 不能包含双引号。" ;;
esac

# ---------------------------------------------------------------- fetch models from gateway

head1 "从网关拉取模型列表"
info "${C_DIM}网关: $GATEWAY_URL${C_RST}"
fetch_models "$GATEWAY_URL" "$API_KEY"
ok "已获取 $(model_count) 个模型"

# ---------------------------------------------------------------- pick model

pick_model
MODEL_SLUG="$SELECTED_MODEL"

# ---------------------------------------------------------------- pre-flight state check

if [ -d "$BACKUP_DIR" ]; then
  # A backup exists → this script presumably installed before.
  # Verify config.toml has the provider section, then take the fast path.
  PROBLEMS=''
  if [ ! -f "$CONFIG_PATH" ]; then
    PROBLEMS="$PROBLEMS
  • 缺少 $CONFIG_PATH"
  else
    grep -q "^\[model_providers\.$PROVIDER_ID\]" "$CONFIG_PATH" 2>/dev/null || PROBLEMS="$PROBLEMS
  • $CONFIG_PATH 中缺少 [model_providers.$PROVIDER_ID]"
  fi

  if [ -n "$PROBLEMS" ]; then
    die "检测到备份目录 $BACKUP_DIR 已存在，
但当前配置与本脚本的预期不符：$PROBLEMS

为避免破坏现有文件或那份备份，本次已中止，未修改任何文件。

建议处理方式（二选一）：
  a) 重新运行本脚本，选择 2 先恢复默认配置，再重新运行选择 1 安装；
  b) 自行检查并删除上述不符合预期的文件（若确认备份目录已无价值，
     连同 $BACKUP_DIR 一起删除），然后重新运行本脚本。"
  fi

  switch_model_only
fi

if [ -f "$MODELS_PATH" ]; then
  die "检测到已存在：
  $MODELS_PATH

该文件不是本脚本写入的（没有找到本脚本的备份目录 ${BACKUP_DIR}）。
本脚本需要创建这个文件。请先自行删除（或另存）该文件，然后重新运行：
  rm $MODELS_PATH
  ${C_B}$INSTALL_CMD${C_RST}"
fi

# ---------------------------------------------------------------- case a: first install

head1 "首次安装（目标模型：${MODEL_SLUG}）"

# ---------------------------------------------------------------- backup

mkdir -p "$BACKUP_DIR" || die "无法创建备份目录：$BACKUP_DIR"

ORIG_EXISTED=1
if [ -f "$CONFIG_PATH" ]; then
  cp "$CONFIG_PATH" "$BACKUP_CONFIG" || die "备份 config.toml 失败"
  ok "已备份 config.toml → $BACKUP_CONFIG"
else
  ORIG_EXISTED=0
  warn "未找到 config.toml，将创建新文件"
fi

# ---------------------------------------------------------------- read the original file

NLINES=0
LINES=()
if [ "$ORIG_EXISTED" -eq 1 ]; then
  while IFS= read -r __l || [ -n "$__l" ]; do
    LINES[$NLINES]="$__l"
    NLINES=$((NLINES+1))
  done < "$CONFIG_PATH"
fi

OUT=()
NOUT=0
INS_AT=0
REPORT=()
NREPORT=0
SEEN=' '

out_add() { OUT[$NOUT]="$1"; NOUT=$((NOUT+1)); }
rep_add() { REPORT[$NREPORT]="$1"; NREPORT=$((NREPORT+1)); }

IDX=0
_consumed_n=0
consume_block() {
  _consumed_n=0
  while [ "$IDX" -lt "$NLINES" ]; do
    _scan_line "${LINES[$IDX]-}"
    IDX=$((IDX+1))
    _consumed_n=$((_consumed_n+1))
    if [ -z "$_mlstate" ] && [ "$_depth" -eq 0 ]; then break; fi
  done
}

truncate_val() {
  local v="$1"
  if [ "${#v}" -gt 58 ]; then printf '%s…' "${v:0:58}"; else printf '%s' "$v"; fi
}

_depth=0
_mlstate=''
CUR_SECTION=''
SKIP_SECTION=0

while [ "$IDX" -lt "$NLINES" ]; do
  line="${LINES[$IDX]-}"
  trimmed=$(_trim "$line")

  is_header=0
  if [ -z "$_mlstate" ] && [ "$_depth" -eq 0 ]; then
    case "$trimmed" in '['*) is_header=1 ;; esac
  fi

  if [ "$is_header" -eq 1 ]; then
    hdr="$trimmed"
    hdr="${hdr#[}"; hdr="${hdr#[}"
    hdr="${hdr%%]*}"
    hdr=$(_trim "$hdr")
    hdr=$(printf '%s' "$hdr" | tr -d "\"'")
    CUR_SECTION="$hdr"
    SKIP_SECTION=0

    case "$hdr" in
      "model_providers.$PROVIDER_ID"|"model_providers.$PROVIDER_ID".*)
        SKIP_SECTION=1
        rep_add "删除旧的 [$hdr]（将以新配置重写）"
        ;;
      profiles|profiles.*)
        SKIP_SECTION=1
        rep_add "删除 [$hdr]  ← profile 会遮蔽 model / model_provider 等设置，且此版本已禁止写入"
        ;;
      auto_review)
        rep_add "保留 [$hdr]  ${C_DIM}(提示: auto_review 若指向 gpt-5.x 模型会使用 fallback 元数据)${C_RST}"
        ;;
      tui.model_availability_nux)
        rep_add "保留 [$hdr]  ${C_DIM}(仅 NUX 计数器，无害)${C_RST}"
        ;;
    esac

    _scan_line "$line"
    IDX=$((IDX+1))
    [ "$SKIP_SECTION" -eq 0 ] && out_add "$line"
    continue
  fi

  if [ -n "$CUR_SECTION" ]; then
    if [ "$SKIP_SECTION" -eq 1 ]; then
      _scan_line "$line"; IDX=$((IDX+1)); continue
    fi
    k=$(_key_of "$line")
    if [ "$k" = "wire_api" ]; then
      v=$(_val_of "$trimmed")
      case "$v" in
        '"chat"'*|"'chat'"*)
          indent="${line%%[![:space:]]*}"
          out_add "${indent}wire_api = \"responses\""
          rep_add "修正 [$CUR_SECTION] 的 wire_api: \"chat\" → \"responses\"  ← 此版本 \"chat\" 会导致 Codex 无法启动"
          _scan_line "$line"; IDX=$((IDX+1)); continue
          ;;
      esac
    fi
    out_add "$line"
    _scan_line "$line"
    IDX=$((IDX+1))
    continue
  fi

  # ---- leading area (top-level keys)
  k=$(_key_of "$line")

  if [ -n "$k" ] && _in_list "$k" "$TARGET_KEYS"; then
    oldv=$(_val_of "$trimmed")
    newv=$(target_value_for "$k")
    consume_block
    out_add "$k = $newv"
    INS_AT=$NOUT
    SEEN="$SEEN$k "
    if [ "$oldv" != "$newv" ]; then
      rep_add "改写 $k: $(truncate_val "$oldv") → $newv"
    fi
    continue
  fi

  if [ -n "$k" ] && _in_list "$k" "$DEL_A"; then
    oldv=$(_val_of "$trimmed")
    consume_block
    case "$k" in
      profile)
        why="profile 会遮蔽 model / model_provider / model_catalog_json，且此版本已禁止写入"
        ;;
      oss_provider)
        why="备用 provider 选择器，会把请求重定向到别处"
        ;;
      openai_base_url)
        why="全局 base_url 覆盖，会劫持请求"
        ;;
      *)
        why="与目标配置冲突"
        ;;
    esac
    rep_add "删除 $k = $(truncate_val "$oldv")  ← $why"
    continue
  fi

  if [ -n "$k" ] && _in_list "$k" "$DEL_B"; then
    oldv=$(_val_of "$trimmed")
    consume_block
    case "$k" in
      model_context_window)
        why="覆盖 models.json 的上下文窗口；报大会导致自动压缩不触发，跑到一半 API 报错"
        ;;
      model_auto_compact_token_limit|model_auto_compact_token_limit_scope)
        why="覆盖自动压缩时机"
        ;;
      base_instructions|model_instructions_file)
        why="覆盖 models.json 里的 base_instructions"
        ;;
      compact_prompt|experimental_compact_prompt_file)
        why="覆盖上下文压缩提示词"
        ;;
      service_tier)
        why="残留值会作为参数发给 API，可能 400"
        ;;
      model_verbosity)
        why="残留值可能超出模型支持范围"
        ;;
      model_reasoning_summary)
        why="models.json 声明 default_reasoning_summary=none，残留值会发送 reasoning.summary"
        ;;
      plan_mode_reasoning_effort)
        why="可能是 xhigh，而 models.json 只声明 low / high / max"
        ;;
      experimental_use_unified_exec_tool)
        why="与 models.json 的 shell_type=shell_command 冲突"
        ;;
      *)
        why="与 models.json 声明矛盾"
        ;;
    esac
    rep_add "删除 $k = $(truncate_val "$oldv")  ← $why"
    continue
  fi

  if [ -n "$k" ] && _in_list "$k" "$WARN_KEYS"; then
    rep_add "保留 $k  ${C_DIM}(提示: 可能引发 fallback 元数据或被远程配置覆盖)${C_RST}"
  fi

  out_add "$line"
  [ -n "$k" ] && INS_AT=$NOUT
  _scan_line "$line"
  IDX=$((IDX+1))
done

# Add any missing target keys (they must land before the first [section])
MISSING=''
for k in $TARGET_KEYS; do
  case "$SEEN" in
    *" $k "*) ;;
    *) MISSING="$MISSING$k " ;;
  esac
done

# ---------------------------------------------------------------- write back

TMP_CONFIG="$CONFIG_PATH.tokenlive-tmp.$$"
: > "$TMP_CONFIG" || die "无法写入临时文件：$TMP_CONFIG"

i=0
while [ "$i" -lt "$NOUT" ]; do
  if [ "$i" -eq "$INS_AT" ] && [ -n "$MISSING" ]; then
    for k in $MISSING; do
      printf '%s = %s\n' "$k" "$(target_value_for "$k")" >> "$TMP_CONFIG"
    done
    MISSING=''
    case "$(_trim "${OUT[$i]}")" in
      '['*) printf '\n' >> "$TMP_CONFIG" ;;
    esac
  fi
  printf '%s\n' "${OUT[$i]}" >> "$TMP_CONFIG"
  i=$((i+1))
done
if [ -n "$MISSING" ]; then
  for k in $MISSING; do
    printf '%s = %s\n' "$k" "$(target_value_for "$k")" >> "$TMP_CONFIG"
  done
fi

{
  printf '\n[model_providers.%s]\n' "$PROVIDER_ID"
  printf 'name = "%s"\n' "$PROVIDER_ID"
  printf 'base_url = "%s"\n' "$GATEWAY_URL"
  printf 'wire_api = "responses"\n'
  printf 'experimental_bearer_token = "%s"\n' "$API_KEY"
} >> "$TMP_CONFIG"

# ---------------------------------------------------------------- write models.json (dynamic)

TMP_MODELS="$MODELS_PATH.tokenlive-tmp.$$"
build_models_json "$TMP_MODELS" "$MODEL_SLUG"

# ---------------------------------------------------------------- validation

VALIDATED_TOML=0
VALIDATED_JSON=0
PY=''
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done

if [ -n "$PY" ]; then
  if "$PY" - "$TMP_MODELS" "$MODEL_SLUG" <<'PYJSON' 2>/dev/null
import json,sys
with open(sys.argv[1],encoding='utf-8') as f:
    d=json.load(f)
ms=d['models']
assert isinstance(ms,list) and len(ms)>=1, 'models must contain at least 1 entry'
slugs={m.get('slug') for m in ms}
assert sys.argv[2] in slugs, sys.argv[2]+' missing'
for m in ms:
    if m.get('slug')==sys.argv[2]:
        assert m.get('priority')==1, 'selected model must have priority 1'
        break
PYJSON
  then
    VALIDATED_JSON=1
  else
    rm -f "$TMP_MODELS" "$TMP_CONFIG"
    die "生成的 models.json 未通过 JSON 校验，已中止（原文件未被修改）。"
  fi

  if "$PY" - "$TMP_CONFIG" <<'PYTOML' 2>/dev/null
import sys
try:
    import tomllib
except ImportError:
    sys.exit(3)
with open(sys.argv[1],'rb') as f:
    c=tomllib.load(f)
assert c.get('model'), 'model missing'
assert c.get('model_provider'), 'model_provider missing'
assert c.get('model_catalog_json'), 'model_catalog_json missing'
assert 'tokenlive' in c.get('model_providers',{}), 'model_providers.tokenlive missing'
PYTOML
  then
    VALIDATED_TOML=1
  else
    rc=$?
    if [ "$rc" -ne 3 ]; then
      rm -f "$TMP_MODELS" "$TMP_CONFIG"
      die "生成的 config.toml 未通过 TOML 校验（可能存在重复 key），已中止。
原文件未被修改，备份在：$BACKUP_DIR"
    fi
  fi
fi

if [ "$VALIDATED_JSON" -eq 0 ]; then
  grep -q "\"$MODEL_SLUG\"" "$TMP_MODELS" || {
    rm -f "$TMP_MODELS" "$TMP_CONFIG"
    die "生成的 models.json 缺少模型 $MODEL_SLUG，已中止。"
  }
fi

# ---------------------------------------------------------------- atomic write

mv "$TMP_MODELS" "$MODELS_PATH" || die "写入 models.json 失败"
mv "$TMP_CONFIG" "$CONFIG_PATH" || die "写入 config.toml 失败"

{
  printf 'script_version=%s\n' "$SCRIPT_VERSION"
  printf 'installed_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'original_config_existed=%s\n' "$ORIG_EXISTED"
  printf 'model_slug=%s\n' "$MODEL_SLUG"
  printf 'gateway_url=%s\n' "$GATEWAY_URL"
  printf 'model_count=%s\n' "$(model_count)"
  printf 'catalog_value=%s\n' "$CATALOG_VALUE"
  printf 'codex_home=%s\n' "$CODEX_HOME_DIR"
  printf -- '--- 对 config.toml 的改动 ---\n'
  i=0
  while [ "$i" -lt "$NREPORT" ]; do
    printf '%s\n' "${REPORT[$i]}"
    i=$((i+1))
  done
} > "$MANIFEST" 2>/dev/null

# ---------------------------------------------------------------- report

save_tokenlive_cache "$GATEWAY_URL" "$API_KEY" "$MODEL_SLUG" || true
ok "已写入 ${MODELS_PATH}（$(model_count) 个模型）"
ok "已更新 $CONFIG_PATH"

if [ "$NREPORT" -gt 0 ]; then
  head1 "对原有配置的改动（共 $NREPORT 项）"
  i=0
  while [ "$i" -lt "$NREPORT" ]; do
    printf '  • %s\n' "${REPORT[$i]}"
    i=$((i+1))
  done
fi

head1 "已写入的配置"
cat <<EOF
  model                  = "$MODEL_SLUG"
  model_provider         = "$PROVIDER_ID"
  preferred_auth_method  = "apikey"
  forced_login_method    = "api"
  model_reasoning_effort = "high"
  model_catalog_json     = "$CATALOG_VALUE"

  [model_providers.$PROVIDER_ID]
  base_url  = "$GATEWAY_URL"
  wire_api  = "responses"
EOF

head1 "校验"
if [ "$VALIDATED_JSON" -eq 1 ]; then ok "models.json 是合法 JSON"
else warn "未找到 Python，仅做了基础检查（models.json）"; fi
if [ "$VALIDATED_TOML" -eq 1 ]; then ok "config.toml 可解析，无重复 key"
else warn "未能做 TOML 解析校验（需 Python 3.11+）"; fi

info ""
ok "安装完成。"
info ""
info "如何确认已生效："
info "  • ChatGPT 桌面端：模型选择器显示${C_B}\"自定义\"${C_RST}即为成功"
info "  • Codex CLI：启动信息中显示 model: ${MODEL_SLUG}"
info ""
info "${C_DIM}若日志出现 \"fallback model metadata\" 或 \"Unknown model\"，"
info "说明 models.json 未被加载，请重新安装。${C_RST}"
head1 "如何切换 / 还原"
info "原配置已备份到 $BACKUP_DIR"
info "再次运行本脚本即可："
info ""
info "  ${C_B}$INSTALL_CMD${C_RST}"
info ""
info "  选 1 刷新模型列表 / 切换模型，选 2 恢复到安装前的配置。"
info ""

exit 0
}
