#!/usr/bin/env bash
# reconcile-skills.sh
#
# 共有スキルプール (~/.agents/skills) と購読宣言 (~/.config/agent-skills/) を同期し、
# 廃止スキルの prune とハーネス向け symlink 投影を行う reconcile スクリプト。
#
# 設計方針:
#   - macOS 標準の Bash 3.2 と Linux Bash の両方で動作する構文のみ使用する
#   - 24時間スロットル（設定ファイル変更時または --force 指定時はバイパス）
#   - 状態・ログ・退避バックアップは chezmoi 管理ツリー外 ($XDG_STATE_HOME/dotfiles/skills)
#   - 個別処理が失敗しても後続を継続し、全成功時のみ同期タイムスタンプを更新する

set -u
set -o pipefail

# ---------------------------------------------------------------------------
# 設定読み込み（優先順位: 呼び出し側環境変数 > machine.env > スクリプト既定値）
# ---------------------------------------------------------------------------
CONFIG_DIR="${DOTFILES_SKILLS_CONFIG_DIR:-$HOME/.config/agent-skills}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/skills"

if [ -f "$CONFIG_DIR/machine.env" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_DIR/machine.env"
fi

DOTFILES_HOST_PROFILE="${DOTFILES_HOST_PROFILE:-unknown}"
DOTFILES_SKILLS_RECONCILE_ENABLED="${DOTFILES_SKILLS_RECONCILE_ENABLED:-true}"
DOTFILES_SKILLS_THROTTLE_SECONDS="${DOTFILES_SKILLS_THROTTLE_SECONDS:-86400}"
DOTFILES_SKILLS_POOL_DIR="${DOTFILES_SKILLS_POOL_DIR:-$HOME/.agents/skills}"
DOTFILES_SKILLS_CLAUDE_DIR="${DOTFILES_SKILLS_CLAUDE_DIR:-$HOME/.claude/skills}"
DOTFILES_SKILLS_CODEX_DIR="${DOTFILES_SKILLS_CODEX_DIR:-$HOME/.codex/skills}"
DOTFILES_SKILLS_ENABLE_MUSE_CUSTOM="${DOTFILES_SKILLS_ENABLE_MUSE_CUSTOM:-false}"
DOTFILES_SKILLS_MUSE_CUSTOM_DIR="${DOTFILES_SKILLS_MUSE_CUSTOM_DIR:-$HOME/workspace/custom-skills}"
DOTFILES_SKILLS_MANAGE_CLAUDE_SYMLINKS="${DOTFILES_SKILLS_MANAGE_CLAUDE_SYMLINKS:-true}"
DOTFILES_SKILLS_ADOPT_EXISTING="${DOTFILES_SKILLS_ADOPT_EXISTING:-false}"
DOTFILES_SKILLS_PRUNE_BACKUP="${DOTFILES_SKILLS_PRUNE_BACKUP:-true}"
DOTFILES_SKILLS_NODE_BIN_DIR="${DOTFILES_SKILLS_NODE_BIN_DIR:-}"
DOTFILES_SKILLS_CLI_PACKAGE="${DOTFILES_SKILLS_CLI_PACKAGE:-skills}"

FORCE="${DOTFILES_SKILLS_FORCE:-0}"
DRY_RUN="${DOTFILES_SKILLS_DRY_RUN:-0}"
SKIP="${DOTFILES_SKILLS_SKIP:-0}"

# コマンドライン引数で上書き
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --adopt-existing)
      DOTFILES_SKILLS_ADOPT_EXISTING="true"
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: reconcile-skills.sh [--force] [--dry-run] [--adopt-existing]

Options:
  --force           24時間スロットルを無視して同期を実行する
  --dry-run         実際の変更を行わず予定コマンドのみ表示する
  --adopt-existing  既存の同名実体ディレクトリを退避して symlink に切り替える
USAGE
      exit 0
      ;;
    *)
      printf '[reconcile-skills] WARN: unknown option: %s\n' "$1" >&2
      ;;
  esac
  shift
done

SUBSCRIPTIONS_FILE="$CONFIG_DIR/subscriptions.tsv"
ALLOWLIST_FILE="$CONFIG_DIR/allowlist.tsv"
PRUNE_FILE="$CONFIG_DIR/prune.txt"

LAST_SYNC_FILE="$STATE_DIR/last_sync_epoch"
CONFIG_HASH_FILE="$STATE_DIR/config_hash"
LOCK_DIR="$STATE_DIR/.lock"
LOG_FILE="$STATE_DIR/reconcile.log"

ERRORS=0
LOCK_ACQUIRED=0
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# ユーティリティ関数
# ---------------------------------------------------------------------------
ensure_state_dir() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

log_msg() {
  local level="$1"
  shift
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  local line="[$ts] [$level] $*"
  printf '%s\n' "$line" >&2
  if [ "$DRY_RUN" != "1" ] && [ -d "$STATE_DIR" ]; then
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

log_info() { log_msg "INFO" "$@"; }
log_warn() { log_msg "WARN" "$@"; }
log_err()  { log_msg "ERROR" "$@"; }

cleanup() {
  if [ "$LOCK_ACQUIRED" = "1" ] && [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

acquire_lock() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  ensure_state_dir
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_ACQUIRED=1
    return 0
  fi

  # 残存ロックの生存確認
  if [ -f "$LOCK_DIR/pid" ]; then
    local old_pid
    old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
      log_warn "Removing stale lock held by dead PID $old_pid"
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        LOCK_ACQUIRED=1
        return 0
      fi
    fi
  fi

  log_warn "Another reconcile-skills process is already running ($LOCK_DIR). Skipping."
  return 1
}

compute_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    printf 'no-hash-tool\n'
  fi
}

compute_config_hash() {
  {
    [ -f "$SUBSCRIPTIONS_FILE" ] && cat "$SUBSCRIPTIONS_FILE"
    printf '\n---ALLOWLIST---\n'
    [ -f "$ALLOWLIST_FILE" ] && cat "$ALLOWLIST_FILE"
    printf '\n---PRUNE---\n'
    [ -f "$PRUNE_FILE" ] && cat "$PRUNE_FILE"
  } | compute_sha256
}

trim_ws() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_safe_skill_name() {
  local name="$1"
  if [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = ".." ]; then
    return 1
  fi
  case "$name" in
    */*|*\\*|*".."*|*" "*|*"	"*|*\**|*\?*|*\[*|*\]*)
      return 1
      ;;
  esac
  return 0
}

is_in_allowlist() {
  local target="$1"
  [ -f "$ALLOWLIST_FILE" ] || return 1
  local line skill _rest
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      ""|\#*) continue ;;
    esac
    IFS=$'\t' read -r skill _rest <<EOF_LINE
$line
EOF_LINE
    skill="$(trim_ws "$skill")"
    if [ "$skill" = "$target" ]; then
      return 0
    fi
  done < "$ALLOWLIST_FILE"
  return 1
}

setup_node_path() {
  local candidate
  for candidate in \
    "$DOTFILES_SKILLS_NODE_BIN_DIR" \
    "$HOME/.local/bin" \
    "$HOME/.volta/bin" \
    "$HOME/.local/share/mise/shims" \
    "/opt/homebrew/bin" \
    "/usr/local/bin"; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      case ":$PATH:" in
        *":$candidate:"*) ;;
        *) PATH="$candidate:$PATH" ;;
      esac
    fi
  done
  export PATH
}

check_node_and_npx() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
    log_warn "node or npx not found in PATH ($PATH). Skipping skills CLI operations."
    return 1
  fi

  local ver major minor
  ver="$(node -p 'process.versions.node' 2>/dev/null || true)"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"

  if [ -z "$major" ] || [ -z "$minor" ]; then
    log_warn "Could not parse Node.js version ('$ver'). Skipping skills CLI operations."
    return 1
  fi

  if [ "$major" -lt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -lt 20 ]; }; then
    log_warn "Node.js >= 22.20 is required for skills CLI (found $ver). Skipping skills CLI operations."
    return 1
  fi
  return 0
}

run_skills_cli() {
  if [ "$DRY_RUN" = "1" ]; then
    log_info "[dry-run] DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 GIT_TERMINAL_PROMPT=0 npx --yes $DOTFILES_SKILLS_CLI_PACKAGE $*"
    return 0
  fi
  # while read ループの stdin 消費および非対話環境でのハングを防ぐため </dev/null と GIT_TERMINAL_PROMPT=0 を付与
  DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 GIT_TERMINAL_PROMPT=0 npx --yes "$DOTFILES_SKILLS_CLI_PACKAGE" "$@" </dev/null
}

build_source_spec() {
  local source="$1"
  local ref="$2"
  if [ -z "$ref" ] || [ "$ref" = "-" ]; then
    printf '%s' "$source"
    return 0
  fi
  case "$source" in
    *"/tree/"*)
      # サブパス指定の tree URL には ref がすでに埋め込まれている
      printf '%s' "$source"
      ;;
    *)
      printf '%s@%s' "$source" "$ref"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. 廃止リストの prune（2段構え: skills CLI + ロック未管理の残骸除去）
# ---------------------------------------------------------------------------
prune_one_path() {
  local base_dir="$1"
  local dir_tag="$2"
  local name="$3"
  local target="$base_dir/$name"

  if [ -L "$target" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log_info "[dry-run] remove symlink: $target"
    else
      rm -f "$target" && log_info "Pruned symlink: $target"
    fi
    return 0
  fi

  if [ -e "$target" ]; then
    if [ "$DOTFILES_SKILLS_PRUNE_BACKUP" = "true" ]; then
      local backup_parent="$STATE_DIR/pruned-backup/$RUN_TS/$dir_tag"
      if [ "$DRY_RUN" = "1" ]; then
        log_info "[dry-run] backup & remove dir: $target -> $backup_parent/$name"
      else
        mkdir -p "$backup_parent"
        mv "$target" "$backup_parent/$name" && log_info "Pruned (backed up): $target -> $backup_parent/$name"
      fi
    else
      if [ "$DRY_RUN" = "1" ]; then
        log_info "[dry-run] rm -rf $target"
      else
        rm -rf "$target" && log_info "Pruned directory: $target"
      fi
    fi
  fi
}

run_prune() {
  local has_cli="$1"
  if [ ! -f "$PRUNE_FILE" ]; then
    log_info "No prune list found ($PRUNE_FILE); skipping prune."
    return 0
  fi

  log_info "Running prune from $PRUNE_FILE"
  local line name
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    name="$(trim_ws "$line")"
    case "$name" in
      ""|\#*) continue ;;
    esac

    if ! is_safe_skill_name "$name"; then
      log_warn "Unsafe skill name in prune list; skipping: '$name'"
      continue
    fi

    if is_in_allowlist "$name"; then
      log_warn "Skill '$name' exists in both allowlist.tsv and prune.txt; skipping prune."
      continue
    fi

    # 第1段: skills CLI でロック整合を保ちながら削除
    if [ "$has_cli" = "1" ]; then
      if [ -e "$DOTFILES_SKILLS_POOL_DIR/$name" ] || [ -L "$DOTFILES_SKILLS_POOL_DIR/$name" ]; then
        if ! run_skills_cli remove -g --agent '*' -y "$name"; then
          log_warn "skills remove failed for '$name' (will still clean leftover paths)"
        fi
      fi
    fi

    # 第2段: ロック未管理の手置き残骸やハーネス側ディレクトリを除去/退避
    prune_one_path "$DOTFILES_SKILLS_POOL_DIR" "agents" "$name"
    prune_one_path "$DOTFILES_SKILLS_CLAUDE_DIR" "claude" "$name"
    prune_one_path "$DOTFILES_SKILLS_CODEX_DIR" "codex" "$name"
    if [ "$DOTFILES_SKILLS_ENABLE_MUSE_CUSTOM" = "true" ]; then
      prune_one_path "$DOTFILES_SKILLS_MUSE_CUSTOM_DIR" "muse-custom" "$name"
    fi
  done < "$PRUNE_FILE"
}

# ---------------------------------------------------------------------------
# 2. 自作リポジトリ丸ごと購読 + 第三者 allowlist 購読 + 既存スキル更新
# ---------------------------------------------------------------------------
run_network_sync() {
  # 先にロック管理下の既存スキルを最新化（この後の allowlist pin 指定で必要版を確定）
  log_info "Updating existing global skills via skills CLI..."
  if ! run_skills_cli update -g -y; then
    log_warn "skills update -g -y failed (continuing with subscriptions/allowlist)"
    ERRORS=$((ERRORS + 1))
  fi

  # 自作リポジトリ等の丸ごと購読
  if [ -f "$SUBSCRIPTIONS_FILE" ]; then
    log_info "Syncing repository subscriptions from $SUBSCRIPTIONS_FILE"
    local line source ref selector _notes spec
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in
        ""|\#*) continue ;;
      esac
      IFS=$'\t' read -r source ref selector _notes <<EOF_SUB
$line
EOF_SUB
      source="$(trim_ws "$source")"
      ref="$(trim_ws "$ref")"
      selector="$(trim_ws "$selector")"
      [ -z "$source" ] && continue
      [ -z "$selector" ] && selector="*"

      spec="$(build_source_spec "$source" "$ref")"
      log_info "Subscribing repo: $spec (skill=$selector)"
      if ! run_skills_cli add "$spec" -g --agent codex --skill "$selector" -y; then
        log_warn "Failed to subscribe repo: $spec"
        ERRORS=$((ERRORS + 1))
      fi
    done < "$SUBSCRIPTIONS_FILE"
  else
    log_info "No subscriptions file found ($SUBSCRIPTIONS_FILE)."
  fi

  # 第三者スキルの allowlist 個別購読
  if [ -f "$ALLOWLIST_FILE" ]; then
    log_info "Syncing third-party allowlist from $ALLOWLIST_FILE"
    local line skill_name source_repo ref _notes spec
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in
        ""|\#*) continue ;;
      esac
      IFS=$'\t' read -r skill_name source_repo ref _notes <<EOF_ALLOW
$line
EOF_ALLOW
      skill_name="$(trim_ws "$skill_name")"
      source_repo="$(trim_ws "$source_repo")"
      ref="$(trim_ws "$ref")"

      if ! is_safe_skill_name "$skill_name"; then
        log_warn "Invalid skill name in allowlist; skipping: '$skill_name'"
        continue
      fi
      if [ -z "$source_repo" ] || [ "$source_repo" = "<TODO:owner/repo>" ]; then
        log_warn "Unresolved source_repo for '$skill_name'; skipping."
        continue
      fi

      spec="$(build_source_spec "$source_repo" "$ref")"
      log_info "Syncing allowlist skill: $skill_name from $spec"
      if ! run_skills_cli add "$spec" -g --agent codex --skill "$skill_name" -y; then
        log_warn "Failed to sync allowlist skill '$skill_name' from '$spec'"
        ERRORS=$((ERRORS + 1))
      fi
    done < "$ALLOWLIST_FILE"
  else
    log_info "No allowlist file found ($ALLOWLIST_FILE)."
  fi
}

# ---------------------------------------------------------------------------
# 3. 共有プールから各ハーネス（Claude Code / Muse custom-skills）への個別 symlink 投影
# ---------------------------------------------------------------------------
sync_pool_symlinks_to() {
  local dest_dir="$1"
  local dest_tag="$2"

  if [ ! -d "$DOTFILES_SKILLS_POOL_DIR" ]; then
    log_info "Pool directory does not exist yet ($DOTFILES_SKILLS_POOL_DIR); skipping symlink sync for $dest_tag."
    return 0
  fi

  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$dest_dir"
  fi

  # 3a. プール内の各スキルを個別 symlink として投影
  local entry name target current_link backup_parent
  for entry in "$DOTFILES_SKILLS_POOL_DIR"/*; do
    [ -d "$entry" ] || continue
    [ -f "$entry/SKILL.md" ] || continue
    name="$(basename "$entry")"
    is_safe_skill_name "$name" || continue

    target="$dest_dir/$name"
    if [ -L "$target" ]; then
      current_link="$(readlink "$target" 2>/dev/null || true)"
      if [ "$current_link" = "$entry" ] || [ "$current_link" = "../../.agents/skills/$name" ]; then
        continue
      fi
      if [ "$DRY_RUN" = "1" ]; then
        log_info "[dry-run] relink $target -> $entry"
      else
        ln -sfn "$entry" "$target" && log_info "Updated symlink ($dest_tag): $target -> $entry"
      fi
    elif [ -e "$target" ]; then
      if [ "$DOTFILES_SKILLS_ADOPT_EXISTING" = "true" ]; then
        backup_parent="$STATE_DIR/adopted-backup/$RUN_TS/$dest_tag"
        if [ "$DRY_RUN" = "1" ]; then
          log_info "[dry-run] adopt existing dir: mv $target $backup_parent/$name && ln -s $entry $target"
        else
          mkdir -p "$backup_parent"
          mv "$target" "$backup_parent/$name"
          ln -s "$entry" "$target"
          log_info "Adopted existing dir ($dest_tag): backed up to $backup_parent/$name and linked to $entry"
        fi
      else
        log_warn "Existing non-symlink at $target conflicts with pool skill '$name'. Skipping (use --adopt-existing or migrate manually)."
      fi
    else
      if [ "$DRY_RUN" = "1" ]; then
        log_info "[dry-run] ln -s $entry $target"
      else
        ln -s "$entry" "$target" && log_info "Linked ($dest_tag): $target -> $entry"
      fi
    fi
  done

  # 3b. プールを指していたリンク切れ symlink のみを掃除（他リンクやベンダー系には触れない）
  if [ -d "$dest_dir" ]; then
    local link_path link_dest
    for link_path in "$dest_dir"/*; do
      [ -L "$link_path" ] || continue
      if [ ! -e "$link_path" ]; then
        link_dest="$(readlink "$link_path" 2>/dev/null || true)"
        case "$link_dest" in
          "$DOTFILES_SKILLS_POOL_DIR"/*|"../../.agents/skills/"*)
            if [ "$DRY_RUN" = "1" ]; then
              log_info "[dry-run] remove broken pool symlink: $link_path -> $link_dest"
            else
              rm -f "$link_path" && log_info "Removed broken pool symlink ($dest_tag): $link_path"
            fi
            ;;
        esac
      fi
    done
  fi
}

# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------
main() {
  if [ "$SKIP" = "1" ] || [ "$DOTFILES_SKILLS_RECONCILE_ENABLED" != "true" ]; then
    log_info "Skills reconcile is disabled (skip=$SKIP, enabled=$DOTFILES_SKILLS_RECONCILE_ENABLED)."
    return 0
  fi

  ensure_state_dir
  acquire_lock || return 0

  setup_node_path

  local now current_hash prev_hash last_sync elapsed need_network
  now="$(date +%s)"
  current_hash="$(compute_config_hash)"
  prev_hash=""
  last_sync=0
  need_network=0

  [ -f "$CONFIG_HASH_FILE" ] && prev_hash="$(cat "$CONFIG_HASH_FILE" 2>/dev/null || true)"
  [ -f "$LAST_SYNC_FILE" ] && last_sync="$(cat "$LAST_SYNC_FILE" 2>/dev/null || printf '0')"

  case "$last_sync" in
    ''|*[!0-9]*) last_sync=0 ;;
  esac
  elapsed=$((now - last_sync))

  if [ "$FORCE" = "1" ]; then
    log_info "Force mode enabled; bypassing 24h throttle."
    need_network=1
  elif [ "$current_hash" != "$prev_hash" ]; then
    log_info "Skill subscription/allowlist/prune config changed; bypassing 24h throttle."
    need_network=1
  elif [ "$elapsed" -ge "$DOTFILES_SKILLS_THROTTLE_SECONDS" ] || [ "$elapsed" -lt 0 ]; then
    log_info "Throttle window elapsed (${elapsed}s >= ${DOTFILES_SKILLS_THROTTLE_SECONDS}s); running sync."
    need_network=1
  else
    log_info "Throttled (${elapsed}s < ${DOTFILES_SKILLS_THROTTLE_SECONDS}s, config unchanged); skipping network sync."
  fi

  local has_cli=0
  if [ "$need_network" = "1" ]; then
    if check_node_and_npx; then
      has_cli=1
    else
      ERRORS=$((ERRORS + 1))
    fi
  fi

  # 廃止リストの prune（設定変更時・同期時・--force 時に実行）
  if [ "$need_network" = "1" ]; then
    run_prune "$has_cli"
  fi

  # ネットワーク経由の購読・更新
  if [ "$need_network" = "1" ] && [ "$has_cli" = "1" ]; then
    run_network_sync
  fi

  # ローカルのハーネス投影（オフラインでも高速・冪等なので毎回整合を確認）
  if [ "$DOTFILES_SKILLS_MANAGE_CLAUDE_SYMLINKS" = "true" ]; then
    sync_pool_symlinks_to "$DOTFILES_SKILLS_CLAUDE_DIR" "claude"
  fi
  if [ "$DOTFILES_SKILLS_ENABLE_MUSE_CUSTOM" = "true" ]; then
    sync_pool_symlinks_to "$DOTFILES_SKILLS_MUSE_CUSTOM_DIR" "muse-custom"
  fi

  # ネットワーク同期が全成功したときのみタイムスタンプと設定ハッシュを記録
  if [ "$need_network" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    if [ "$ERRORS" -eq 0 ]; then
      printf '%s\n' "$now" > "$LAST_SYNC_FILE"
      printf '%s\n' "$current_hash" > "$CONFIG_HASH_FILE"
      log_info "Reconcile completed successfully (host_profile=$DOTFILES_HOST_PROFILE)."
    else
      log_warn "Reconcile finished with $ERRORS error(s); timestamp not updated so next run will retry."
      return 1
    fi
  fi

  return 0
}

main "$@"
