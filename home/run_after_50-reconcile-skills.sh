#!/usr/bin/env bash
# run_after_50-reconcile-skills.sh
#
# chezmoi apply 完了後にスキル同期を実行するフック。
# 安全策: reconcile が失敗しても警告を出すだけで終了コード 0 を返し、
#         chezmoi apply 全体は絶対に止めない。

set -u

SCRIPT="$HOME/.local/libexec/dotfiles/reconcile-skills.sh"

if [ "${DOTFILES_SKILLS_SKIP:-0}" = "1" ]; then
  printf '[chezmoi:reconcile-skills] Skipped via DOTFILES_SKILLS_SKIP=1\n' >&2
  exit 0
fi

if [ ! -x "$SCRIPT" ]; then
  printf '[chezmoi:reconcile-skills] WARN: script not found or not executable: %s\n' "$SCRIPT" >&2
  exit 0
fi

if ! "$SCRIPT"; then
  printf '[chezmoi:reconcile-skills] WARN: skills reconcile encountered errors (continuing chezmoi apply).\n' >&2
fi

exit 0
