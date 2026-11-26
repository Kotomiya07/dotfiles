# dotfiles (chezmoi — A-3 スコープ: Agent Skills 配布)

Agent Skills の共有プール（`~/.agents/skills`）への購読同期、廃止スキルの prune、および各ハーネス（Claude Code / Codex / Antigravity / Muse custom-skills）への接続を管理する chezmoi dotfiles リポジトリです。

## スコープ（方針 A-3）

- **対象**:
  - 共有プール `~/.agents/skills/` への購読同期（自作 `Kotomiya07/skills` + 第三者 allowlist）
  - 廃止スキル（`prune.txt`）の 2 段構え削除・退避
  - Claude Code（`~/.claude/skills/<name>` 個別 symlink）、Codex（`~/.agents/skills` 直読み）、Antigravity（`~/.gemini/config/skills.json`）、Muse VM（`~/workspace/custom-skills/<name>` 個別 symlink、オプトイン）の接続
- **対象外（初回スコープ外）**:
  - `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` 等のエージェント指示ファイル（`manage_claude_md = false` 固定。テンプレート本体は誤上書き防止のため未配置）

## 構成

- `.chezmoiroot`: `home` をソースルートに指定
- `home/.chezmoi.toml.tmpl`: ホストプロファイルとスキル同期設定を生成
- `home/.chezmoiignore.tmpl`: 指示ファイル未管理時の保護ガード
- `home/dot_config/agent-skills/`:
  - `machine.env.tmpl`: マシン固有設定（環境変数による一時上書き対応）
  - `subscriptions.tsv`: 丸ごと購読リポジトリ（`Kotomiya07/skills/tree/main/skills`）
  - `allowlist.tsv`: 第三者スキルの個別購読 allowlist
  - `prune.txt`: 廃止・残骸スキル 8 件
- `home/dot_gemini/config/skills.json`: Antigravity 向け共有プール参照設定
- `home/dot_local/libexec/dotfiles/executable_reconcile-skills.sh`: reconcile 本体（Bash 3.2 互換）
- `home/run_after_50-reconcile-skills.sh`: `chezmoi apply` 後フック（fail-open）

## 使い方

```bash
# 初期化と適用
chezmoi init <repo-url-or-path>
chezmoi diff
chezmoi apply -v

# スキル同期のみ単体テスト / 強制実行
~/.local/libexec/dotfiles/reconcile-skills.sh --dry-run --force
~/.local/libexec/dotfiles/reconcile-skills.sh --force

# 一時的に reconcile を無効化して apply
DOTFILES_SKILLS_SKIP=1 chezmoi apply
```
