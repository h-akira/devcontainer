# devcontainer

Claude Code（および他のAIコーディングエージェント）を安全に使うための Dev Container 設定。
親プロジェクトから submodule として `.devcontainer/` に取り込んで利用する。

## 特徴

- **ファイアウォール**: ホワイトリスト方式で AWS / GitHub / npm / PyPI / Anthropic API などにのみ通信を許可
- **AWS CLI**: SSO ログイン（`aws sso login --use-device-code`）と手動アクセスキー配置の両方をサポート
- **MCP サーバー**: AWS Documentation MCP / AWS CDK MCP / Context7 を同梱（`.mcp.json` で設定）
- **dotfiles**: zsh (Zinit + Powerlevel10k) / vim (vim-plug) / tmux (TPM + Dracula) を自動セットアップ
- **事故防止**: ホストとの取り違えを防ぐためコンテナ内シェルのプロンプト色を変更

## セットアップ（親プロジェクト側）

```bash
# 1. .devcontainer を submodule として追加
git submodule add git@github.com:h-akira/devcontainer.git .devcontainer

# 2. .gitignore に .mcp.json を追加（API キーが入るため）
echo ".mcp.json" >> .gitignore

# 3. VSCode で「Reopen in Container」
#    → init-*.sh が自動で zsh / vim / tmux / .mcp.json をセットアップ

# 4. （任意）Context7 を使う場合は API キーを設定
vim .mcp.json
```

## AWS CLI の使い方

### SSO（推奨）

```bash
# 初回のみプロファイル作成（対話）
aws configure sso

# ログイン（コンテナ内ブラウザがないため --use-device-code 必須）
aws sso login --use-device-code

# 表示された URL をホストブラウザで開いてコードを入力
```

### アクセスキー手動配置

```bash
vim ~/.aws/credentials
# あるいは
aws configure
```

### マネジメントコンソール認証情報（IAM ユーザー / フェデレーション）

AWS CLI v2.32.0 以降の `aws login --remote` も使える：

```bash
aws login --remote
```

## ファイル構成

```
.devcontainer/
├── devcontainer.json      # Dev Container メイン設定
├── Dockerfile             # コンテナイメージ定義
├── init-firewall.sh       # ファイアウォール設定
├── init-claude.sh         # Claude Code settings.json 配置
├── init-zsh.sh            # zsh セットアップ
├── init-vim.sh            # vim セットアップ
├── init-tmux.sh           # tmux セットアップ
├── init-mcp.sh            # /workspace/.mcp.json 雛形配置
├── config/
│   ├── claude/settings.json
│   ├── zsh/{dot.zshrc, zinitrc, bindkeyrc, dircolors, dot.p10k.zsh, add.zshrc}
│   ├── vim/{dot.vimrc, autoload/plug.vim, template/}
│   ├── tmux/dot.tmux.conf
│   └── mcp/mcp.json.template
└── develop/               # 開発用（要件・QA など。利用側では無視してよい）
```

## 永続化されるデータ（Docker ボリューム）

`${devcontainerId}` でプロジェクトごとに分離される。

| ボリューム名 | パス | 用途 |
|------------|------|------|
| `devcontainer-bashhistory-...` | `/commandhistory` | シェル履歴 |
| `devcontainer-claude-...` | `/home/node/.claude` | Claude Code 設定・認証 |
| `devcontainer-aws-...` | `/home/node/.aws` | SSO トークン・アクセスキー |
| `devcontainer-zinit-...` | `/home/node/.local/share/zinit` | Zinit 本体 + プラグイン |
| `devcontainer-vim-plugged-...` | `/home/node/.vim/plugged` | vim-plug プラグイン |
| `devcontainer-tmux-plugins-...` | `/home/node/.tmux/plugins` | TPM プラグイン |

ボリューム削除でクリーンに戻せる：

```bash
docker volume ls | grep devcontainer-
docker volume rm <name>
```

## GitHub の認証

セキュリティのため、コンテナ内には GitHub の認証情報を持ち込まない方針。
`git push` / `git pull` / `gh pr create` などはホスト側ターミナルから実行する。

VSCode 上では：
- 開発用ウィンドウ = Dev Container 接続中（コンテナ内で編集・コミット）
- 同期用ウィンドウ = ホスト側で同じプロジェクトを開く（push/pull 専用）

の 2 ウィンドウ運用が分かりやすい。

## カスタマイズ

| 変更したい項目 | 編集する場所 |
|--------------|-------------|
| 許可ドメイン追加 | `init-firewall.sh` |
| AWS CLI バージョン | `devcontainer.json` の `AWSCLI_VERSION` |
| Claude Code バージョン | `devcontainer.json` の `CLAUDE_CODE_VERSION` |
| タイムゾーン | ホスト側で `export TZ=...` または `devcontainer.json` |
| MCP サーバー | `config/mcp/mcp.json.template`（既存ユーザーは `.mcp.json` を直接編集） |
| zsh / vim / tmux 設定 | `config/{zsh,vim,tmux}/` |

## 詳細な設計と意思決定の記録

`develop/REQUIREMENTS.md` と `develop/QA.md` を参照。
