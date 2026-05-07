# devcontainer

Claude Code（および他のAIコーディングエージェント）を安全に使うための Dev Container 設定。
親プロジェクトから submodule として `.devcontainer/` に取り込んで利用する。

## 特徴

- **ファイアウォール**: ホワイトリスト方式で AWS / GitHub / npm / PyPI / Anthropic API などにのみ通信を許可
- **AWS CLI**: SSO ログイン（`aws sso login --use-device-code`）と手動アクセスキー配置の両方をサポート
- **MCP サーバー**: AWS Documentation MCP / AWS CDK MCP / Context7 を同梱（`.mcp.json` で設定）
- **dotfiles**: zsh (Zinit + Powerlevel10k) / Neovim (lazy.nvim) / tmux (TPM + Dracula) を自動セットアップ
- **エディタ**: Neovim 0.12+（`vi` / `vim` コマンドも Neovim を起動するよう symlink 済み）
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
├── init-nvim.sh           # neovim セットアップ
├── init-tmux.sh           # tmux セットアップ
├── init-mcp.sh            # /workspace/.mcp.json 雛形配置
├── init-all.sh            # 上記を順に実行する集約ラッパー
├── config/
│   ├── claude/settings.json
│   ├── zsh/{dot.zshrc, zinitrc, bindkeyrc, dircolors, dot.p10k.zsh, add.zshrc}
│   ├── nvim/{init.lua, lua/{config,plugins}/, template/, add.lua, lua/plugins/add.lua}
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
| `devcontainer-nvim-data-...` | `/home/node/.local/share/nvim` | lazy.nvim 本体 + Neovim プラグイン |
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

## sudo の運用

本リポジトリは **submodule として取り込む共通利用** と **vendor in した（フォーク化した）プロジェクト固有利用** の
2 通りの運用を想定しており、sudo の扱いも運用形態によって変える設計。

### submodule 運用（既定）

コンテナ内の `node` ユーザーには **パスワード付き sudo** が許可されている。
パスワードは `devcontainer`（Dockerfile の `SUDO_PASSWORD` build arg で変更可能）。

```bash
sudo apt update
sudo apt install <package>
# Password: devcontainer
```

`init-firewall.sh` で `deb.debian.org` / `security.debian.org` を許可しているため、
コンテナ内で apt から実際にパッケージを取得できる。

#### この設計の意図

- submodule のままでは `.devcontainer/Dockerfile` を編集すると submodule の dirty diff になり扱いが面倒
- そこで **コンテナ内の対話 sudo** で `apt install` を許す妥協を採った
- **AI（Claude Code 等）はパスワードを対話入力できない**ため、sudo プロンプトで実質的にブロックされる
- 人間のユーザーは VSCode の統合ターミナル等で対話的に sudo を使える

#### 注意

- パスワードはイメージ層に焼き込まれている（`docker history` で見える可能性）
- `sudo apt install` で入れたパッケージは **コンテナ Rebuild で消える**（Stop/Start では残る）
- 継続的に必要なパッケージは「フォーク化して Dockerfile に焼き込む」方が筋が良い

### フォーク化（vendor in）した運用

`.devcontainer/` を submodule から離脱させて親プロジェクトに vendor in した場合、
**sudo 機能はコメントアウトで無効化することを推奨する**。理由：

- Dockerfile を自由に編集できるので、必要なパッケージは apt-get install リストに追記して Rebuild する
- runtime の sudo が不要になる
- AI 隔離が strict（パスワードを巡るゲームを完全に排除できる）
- パスワードがイメージ層に残る footgun も解消

#### 無効化手順

`Dockerfile` 末尾付近の以下のブロックをコメントアウト：

```dockerfile
# ARG SUDO_PASSWORD=devcontainer
# RUN echo "node:${SUDO_PASSWORD}" | chpasswd && \
#   usermod -aG sudo node
```

合わせて `init-firewall.sh` の Debian 関連の許可（`deb.debian.org`, `security.debian.org`）も削っておくと、
ファイアウォールがミニマムに保てる。

submodule から離脱する手順は次節を参照。

## プロジェクト固有のカスタマイズ

汎用的な開発環境を共通化するため、本リポジトリは submodule として取り込む運用を想定している。
ただしプロジェクト固有の事情で `.devcontainer/` の中身（Dockerfile, init-*.sh, config/* など）を
改変したい場合は、**submodule から離脱して通常のディレクトリに切り替える**運用を推奨する。

### submodule から離脱する手順

```bash
# 1. submodule の登録を解除し、ワーキングツリーから削除
git submodule deinit -f .devcontainer
git rm -f .devcontainer
rm -rf .git/modules/.devcontainer

# 2. 同じ内容を通常のディレクトリとしてクローンし直す
git clone https://github.com/h-akira/devcontainer.git .devcontainer
rm -rf .devcontainer/.git

# 3. 親プロジェクトにコミット
git add .devcontainer
git commit -m "vendor in .devcontainer for project-specific customization"
```

これで `.devcontainer/` は親プロジェクトの一部になり、Dockerfile に
プロジェクト固有のパッケージを追加するなど自由に編集できる。

### 上流の更新を取り込みたい場合

離脱後は基本的に独自路線として運用する。上流の更新を取り込みたい場合は、
個別ファイル単位で `wget` などで取得して手動でマージする。
頻繁に上流追従したい用途なら、submodule のままにして必要なパッケージは
`sudo apt install` で都度追加（コンテナ Rebuild で消える前提）するか、
本リポジトリに上流コントリビュートする方が長期的に楽。

## カスタマイズ

| 変更したい項目 | 編集する場所 |
|--------------|-------------|
| 許可ドメイン追加 | `init-firewall.sh` |
| AWS CLI バージョン | `devcontainer.json` の `AWSCLI_VERSION` |
| Claude Code バージョン | `devcontainer.json` の `CLAUDE_CODE_VERSION` |
| タイムゾーン | ホスト側で `export TZ=...` または `devcontainer.json` |
| MCP サーバー | `config/mcp/mcp.json.template`（既存ユーザーは `.mcp.json` を直接編集） |
| zsh / nvim / tmux 設定 | `config/{zsh,nvim,tmux}/` |
| Neovim バージョン | `Dockerfile` の `NVIM_VERSION`（AppImage タグ） |
| sudo パスワード | `devcontainer.json` の `build.args.SUDO_PASSWORD` |

## 詳細な設計と意思決定の記録

`develop/REQUIREMENTS.md` と `develop/QA.md` を参照。

## ライセンス

[MIT License](LICENSE) で提供する。

`Dockerfile` / `devcontainer.json` / `init-firewall.sh` は
[anthropics/claude-code](https://github.com/anthropics/claude-code) の `.devcontainer/`
を参考に作成した。Anthropic公式ドキュメント（[Development containers](https://code.claude.com/docs/en/devcontainer#try-the-reference-container)）は
このリファレンス構成について次のように案内している:

> It is provided as a working example rather than a maintained base image; use it to see how the pieces fit together before applying them to your own configuration.
>
> To use this configuration with your own project, copy the `.devcontainer/` directory into your repository and adjust the Dockerfile for your toolchain (...)
