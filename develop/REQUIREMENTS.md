# Dev Container 要件と対応方針

## 背景・目的

Claude Code（および他のAIコーディングエージェント）を安全に使うため、Dev Container を使った隔離環境を構築する。
このリポジトリは将来的に `h-akira/devcontainer` として独立させ、各プロジェクトから submodule として `.devcontainer/` に取り込む形で利用する。

### モチベーション

1. **AIによる悪意のあるコマンド・スクリプト実行を阻止したい**
   - ホストマシンのファイル・設定への意図しないアクセスを防ぐ
   - `rm -rf` などの破壊的コマンドの影響をコンテナ内に閉じ込める
2. **外部サーバーへの迷惑を避けたい**
   - AIが意図せず外部APIを叩く・スクレイピングするのを防ぐ
   - アウトバウンド通信を必要なものだけに制限する

→ Anthropic公式の Dev Container（`.devcontainer/`）がこの要件を満たすため、これをベースにカスタマイズする。

---

## リポジトリ構成（最終形）

このリポジトリ自体が submodule として親プロジェクトの `.devcontainer/` に取り込まれる前提：

```
.devcontainer/                    # = h-akira/devcontainer リポジトリのルート
├── devcontainer.json
├── Dockerfile
├── init-firewall.sh              # ファイアウォール設定
├── init-zsh.sh                   # zsh セットアップ
├── init-vim.sh                   # vim セットアップ
├── init-tmux.sh                  # tmux セットアップ
├── init-mcp.sh                   # /workspace/.mcp.json の雛形配置
├── config/
│   ├── claude/
│   │   └── settings.json         # Claude Code 共通設定（permissions.deny 等）
│   ├── zsh/
│   │   ├── dot.zshrc
│   │   ├── zinitrc
│   │   ├── bindkeyrc
│   │   ├── dircolors
│   │   ├── dot.p10k.zsh          # 色をホストと変える
│   │   └── add.zshrc             # コンテナ固有の追加設定
│   ├── vim/
│   │   ├── dot.vimrc
│   │   ├── autoload/plug.vim
│   │   └── template/
│   ├── tmux/
│   │   └── dot.tmux.conf
│   └── mcp/
│       └── mcp.json.template     # → /workspace/.mcp.json（初回のみ）
├── develop/                      # 開発用（submodule として使う側からも見えるが、害はない）
│   ├── REQUIREMENTS.md
│   └── QA.md
└── README.md                     # submodule として使う側向け
```

**git管理外（`.gitignore`）:**
- `references/` — 開発時の参考資料

---

## 要件と対応方針

### 1. AWS CLI を使いたい（必須）

#### 採用方針: コンテナ内で `aws sso login --use-device-code` を実行（シナリオ A）

ホストの `~/.aws` はマウントせず、コンテナ内で完結させる。アクセスキー手動配置も同じ `~/.aws` ボリュームに保存可能。

##### 認証方法の使い分け

| 方法 | コマンド | 用途 |
|------|---------|------|
| **SSO（推奨）** | `aws sso login --use-device-code` | IAM Identity Center を使う通常運用 |
| **アクセスキー手動配置** | `vim ~/.aws/credentials` | SSO が使えない、または特定 IAM ユーザーで作業したいとき |
| **`aws login --remote`** | `aws login --remote` | コンソール認証情報を使うケース（IAM Identity Center 不使用時、v2.32.0+） |

##### `aws sso login` と `aws login` の違い

- **`aws sso login`**: IAM Identity Center (SSO) 用。`~/.aws/sso/cache/` にトークンを保存。
- **`aws login`** (v2.32.0+): AWSマネジメントコンソールの認証情報（rootユーザー、IAMユーザー、フェデレーションIdP）を使うコマンド。IAM Identity Center は対象外。`--remote` オプションでブラウザなし環境にも対応。

両者は別コマンドだが、いずれも `~/.aws/` 配下を使うため、構成上は両方を許容する。

##### SSO のセッション持続時間

| セッション種別 | デフォルト | 最大 |
|--------------|-----------|------|
| User interactive session（AWSアクセスポータル） | 8 時間 | 90 日（管理者設定） |
| IAM role session（CLI 一時クレデンシャル） | permission set 依存 | 12 時間 |

ホストブラウザで AWS Access Portal にログイン中なら、`aws sso login` 実行時に「許可」ボタンを押すだけで完了する（パスワード・MFA 再入力不要）。実運用では数日〜数十日に1回のログインで済む。

##### Dockerfile への追加

```dockerfile
# AWS CLI v2 のインストール（バージョンを ARG で固定）
ARG AWSCLI_VERSION=2.32.0
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) AWS_ARCH="x86_64" ;; \
        arm64) AWS_ARCH="aarch64" ;; \
    esac && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWSCLI_VERSION}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    sudo ./aws/install && \
    rm -rf awscliv2.zip aws/
```

バージョンは ARG で固定し、将来の更新を容易にする。

##### devcontainer.json の mounts

```json
"mounts": [
  "source=devcontainer-aws-${devcontainerId},target=/home/node/.aws,type=volume"
]
```

- `${devcontainerId}` でプロジェクト分離
- SSO トークンキャッシュ・アクセスキー（手動配置）両方を同じボリュームに保存

##### 初回セットアップ手順（コンテナ内）

```bash
# パターン 1: SSO
aws configure sso              # 初回のみ（プロファイル作成）
aws sso login --use-device-code

# パターン 2: アクセスキー手動配置
vim ~/.aws/credentials         # 直接書く
# または
aws configure                  # 対話的に設定
```

##### マルチプロファイル対応

`~/.aws/config` で複数プロファイルを定義可能。デフォルトプロファイル指定の方法はユーザー任せ：
- `default` プロファイルを使う
- `AWS_PROFILE` 環境変数で切り替え
- 各コマンドで `--profile` を明示

具体的な命名規則・運用は親プロジェクト側で決める。

---

### 2. ファイアウォール — AWS 関連ドメインの許可

#### 採用方針: AWS の公開 IP レンジリスト（`ip-ranges.json`）を使って一括許可

`https://ip-ranges.amazonaws.com/ip-ranges.json` から AWS の全パブリック IP CIDR を取得し、`ipset` に追加する。

##### メリット

- `*.amazonaws.com` / `*.aws` / `*.awsapps.com` をワイルドカードで扱う問題を回避
- SSO の Start URL（`d-xxxxxxxxxx.awsapps.com`）も AWS の IP レンジ内のため、ハードコード不要
- リージョン・サービスごとの許可を細かく書く必要がない（メンテ負荷低減）
- AWS 側で IP 追加があっても自動追従

##### デメリット

- 「AWS 関連は全部許可」になるため、許可リストの精度は落ちる（許容する）
- ファイルサイズが大きい（10MB超）→ `ipset` の上限（デフォルト65536件）には収まる範囲

##### 実装イメージ（init-firewall.sh への追加）

```bash
echo "Fetching AWS IP ranges..."
aws_ranges=$(curl -s https://ip-ranges.amazonaws.com/ip-ranges.json)
if [ -z "$aws_ranges" ]; then
    echo "ERROR: Failed to fetch AWS IP ranges"
    exit 1
fi

# IPv4 全リージョン・全サービスを許可
echo "$aws_ranges" | jq -r '.prefixes[].ip_prefix' | aggregate -q | while read -r cidr; do
    ipset add allowed-domains "$cidr"
done
```

##### 既存の許可ドメインに追加すべきもの

MCP サーバー（uvx / npx）用：

```bash
"pypi.org"                         # uvx が awslabs パッケージを取得
"files.pythonhosted.org"           # PyPI のファイルホスト
"docs.aws.amazon.com"              # AWS Documentation MCP の参照先
"context7.com"                     # Context7 API
"mcp.context7.com"                 # Context7 MCP エンドポイント
```

`registry.npmjs.org` は既存（npm 用）で、Context7 の `npx` もこれを使う。

GitHub プラグイン取得用（要検証）：

```bash
"raw.githubusercontent.com"
"codeload.github.com"
"objects.githubusercontent.com"
```

GitHub の IP レンジ動的取得（`api.github.com/meta`）でカバーされている可能性が高い。

---

### 3. Claude Code の設定（`~/.aws` への簡易アクセス制限）

#### 採用方針: `permissions.deny` で `~/.aws/**` を簡易的に deny

アクセスキー手動配置のケースを考慮し、AI が安易に認証情報を読みに行かないよう、Claude Code の `permissions.deny` で簡易的に保護する。

##### 設定ファイル

`config/claude/settings.json`（コンテナ内グローバル `/home/node/.claude/settings.json` に配置）：

```json
{
  "permissions": {
    "deny": [
      "Read(~/.aws/**)"
    ]
  }
}
```

##### 設計意図

- **厳密な防御ではない** — Bash 経由（`cat ~/.aws/credentials`）は迂回可能
- 「AI が安易に Read ツールで読みに行かないようにする」程度の位置付け
- Sandbox `denyRead` は使わない（AWS CLI 実行に影響する可能性 + 設定が複雑）
- AWS CLI 自体の動作には影響しない（CLI は子プロセス内で `~/.aws` を読む）

##### 配置の注意点（要検証）

`/home/node/.claude` は既存のボリュームマウント対象（公式 devcontainer.json）のため、Dockerfile の `COPY` がボリュームに上書きされる可能性がある。

- 案 1: `init-claude.sh` を作って `postStartCommand` で配置する
- 案 2: 設定をプロジェクトローカル（`/workspace/.claude/settings.json`）に置き、`init-mcp.sh` 等で雛形をコピーする

→ 動作検証で決定する（残課題 C 参照）。

---

### 4. GitHub を使いたい（必須）

#### 方針：**認証が必要な操作はホスト側ターミナルで実行する**

`git push` / `git pull` / `git fetch` など認証が必要なコマンドは、そもそも AI に実行させる必要がない。コンテナ内には認証情報を一切持ち込まず、リモートとの同期だけホスト側で行う。

##### 役割分担

| 場所 | 実行するコマンド |
|------|----------------|
| **コンテナ内（AI含む）** | 編集、ビルド、テスト、`git status` / `git diff` / `git log` / `git add` / `git commit` など |
| **ホスト側ターミナル** | `git push` / `git pull` / `git fetch`、`gh pr create` など認証が必要なコマンド全般 |

コミットまではコンテナ内で完結させ、リモートとの同期だけホストで実施する。

##### この方針のメリット

- **AI が認証情報に一切触れられない** — トークンも SSH 鍵もコンテナに入っていない
- **鍵・トークンの管理場所が一元化** — ホスト側の既存設定をそのまま使える
- **セットアップが不要** — 新規コンテナを立てるたびに認証し直す手間がない
- **最小権限の原則に合致** — AI に不要な権限は与えない

##### VSCode でのホスト/コンテナ切り替え

VSCode の Dev Container 接続中でも、ホスト側のターミナルは開ける：

1. **別ウィンドウ方式** — ホスト側のプロジェクトフォルダを通常の VSCode ウィンドウで開き、そちらのターミナルを push/pull 用に使う
2. **ローカルターミナル起動** — コマンドパレット → `Terminal: Create New Integrated Terminal (Local)`
3. **OS ネイティブのターミナル** — iTerm2 や Terminal.app などを直接使う

1の「別ウィンドウ方式」が一番わかりやすい。片方を「開発作業用（コンテナ）」、もう片方を「リモート同期用（ホスト）」として使い分ける。

##### 既に対応済み

- `gh` コマンドは Dockerfile でインストール済み（参照系コマンドには便利なので残す）
- GitHub の IP レンジは `init-firewall.sh` で許可済み（`git fetch` などローカル的に使う場合のため残す）

---

### 5. MCP サーバー（documentation系、Context7）

#### 使いたいサーバー

| サーバー | 用途 | ランタイム | 認証 |
|---------|------|-----------|------|
| `awslabs.cdk-mcp-server` | AWS CDK のドキュメント・支援 | `uvx`（Python） | 不要 |
| `awslabs.aws-documentation-mcp-server` | AWS ドキュメント検索 | `uvx`（Python） | 不要 |
| `context7` | ライブラリの最新ドキュメント取得 | `npx`（Node.js） | **API キー必要** |

#### 配置方針：プロジェクトルートに `.mcp.json` を置く

Claude Code は **プロジェクトルートの `.mcp.json` を自動で読み込む**仕様。これを利用して：

```
親プロジェクト/
├── .gitignore              # .mcp.json を追加（必須）
├── .mcp.json               # ← ここに配置（バインドマウントで /workspace/.mcp.json に同期）
├── .devcontainer/          # submodule
│   └── config/mcp/
│       └── mcp.json.template
└── ...
```

メリット：
- コンテナ内とホストで同じファイル（`/workspace` バインドマウント経由）
- ホストのエディタでもコンテナ内でも編集可能
- Docker ボリュームの永続化を考えなくて良い（バインドマウントで自動的に永続化）
- ホスト側に環境変数や 1Password などの仕組みを用意しなくて良い

#### API キー（Context7）の扱い

**方針：コンテナ内で `.mcp.json` に直接貼り付ける。ホスト側にはAPIキーを置かない。**

##### セキュリティ評価

| 経路 | この方式での状態 |
|------|---------------|
| ホストの環境変数 / dotfiles | **入らない** |
| Git リポジトリ | gitignore で除外 |
| Docker ボリューム | バインドマウントなので関係なし |
| AI から読まれるリスク | あり（コンテナ内で読める） |

AI が `.mcp.json` を読めるのは原理的に避けられない（MCP サーバー起動に必要）。これは API キーの権限を最小化することで対処する。

##### 雛形（`mcp.json.template`）

`config/mcp/mcp.json.template` に Context7 の API キーだけ空にした形で同梱：

```json
{
  "mcpServers": {
    "awslabs.cdk-mcp-server": {
      "command": "uvx",
      "args": ["awslabs.cdk-mcp-server@latest"],
      "env": { "FASTMCP_LOG_LEVEL": "ERROR" },
      "disabled": false,
      "autoApprove": []
    },
    "awslabs.aws-documentation-mcp-server": {
      "command": "uvx",
      "args": ["awslabs.aws-documentation-mcp-server@latest"],
      "env": {
        "FASTMCP_LOG_LEVEL": "ERROR",
        "AWS_DOCUMENTATION_PARTITION": "aws"
      },
      "disabled": false,
      "autoApprove": []
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"],
      "env": {
        "CONTEXT7_API_KEY": ""
      }
    }
  }
}
```

#### init-mcp.sh の責務

```bash
#!/bin/bash
# /workspace/.mcp.json が存在しない場合のみ雛形をコピー
if [ ! -f /workspace/.mcp.json ]; then
  cp /workspace/.devcontainer/config/mcp/mcp.json.template /workspace/.mcp.json
  echo "→ /workspace/.mcp.json を作成しました"
  echo "   Context7 API キーを設定してください: vim /workspace/.mcp.json"
fi
```

既存の `.mcp.json` は **絶対に上書きしない**（ユーザーが書いた API キーを破壊しないため）。

#### Dockerfile への追加

```dockerfile
# uv のインストール（awslabs MCP サーバー用、uvx を使うため）
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
```

`npx`（Context7 用）は Node.js に同梱されているため追加不要。

#### 親プロジェクト側でのセットアップ手順（README に書く内容）

```bash
# 1. .devcontainer を submodule として追加
git submodule add git@github.com:h-akira/devcontainer.git .devcontainer

# 2. .gitignore に .mcp.json を追加
echo ".mcp.json" >> .gitignore

# 3. Dev Container を起動（VSCode で Reopen in Container）
#    → init-mcp.sh が雛形を /workspace/.mcp.json にコピー

# 4. Context7 API キーを設定
vim .mcp.json
```

---

### 6. zsh / vim / tmux（ユーザー設定の持ち込み）

#### 方針：`init-*.sh` パターンで devcontainer リポジトリ内に同梱する

`init-firewall.sh` と同じ思想で、`init-zsh.sh` / `init-vim.sh` / `init-tmux.sh` を `.devcontainer/` 内に置き、`postStartCommand` で順次実行する。設定ファイル本体（zshrc, vimrc, tmux.conf など）も devcontainer リポジトリ内に **コピーして同梱** する。

#### 既存リポジトリと devcontainer 用コピーの関係

`h-akira/zsh`, `h-akira/vim`, `h-akira/tmux` は既に public で存在し、ホストでも使っている。これらを **submodule として取り込まず、devcontainer 用にコピーして独立管理する**。

理由：
- devcontainer 専用の調整（p10k 色変更、不要設定の削除など）が入る
- 元リポジトリと完全同期する必要がない
- submodule のネスト（プロジェクト → devcontainer → 設定リポジトリ）を避けられる

トレードオフ：
- 元リポジトリの更新を手動で取り込む必要がある（差分を意識的に見る）
- 設定が分岐していくが、それは devcontainer 用途として意図的なもの

#### 各設定の詳細

##### zsh

| 項目 | 内容 |
|------|------|
| プラグインマネージャ | **Zinit**（oh-my-zsh ではない） |
| テーマ | **Powerlevel10k** |
| プラグイン | `zsh-256color`, `zsh-autosuggestions`, `zsh-completions`, `fast-syntax-highlighting`, `history-search-multi-word`, `git-open`, `k` |
| 初回動作 | Zinit が `github.com` からプラグインを自動ダウンロード |
| 環境固有設定 | `~/.zsh/add.zshrc` で吸収する設計 |

**ホストとコンテナの取り違え事故防止（重要）**

ローカルターミナルとコンテナ内ターミナルを取り違えて push などを誤実行する事故を防ぐため、視覚的に明確に区別する：

- **p10k のディレクトリ背景色をホストと別の色にする**
  ```bash
  # config/zsh/dot.p10k.zsh
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=5   # マゼンタ系などホストと違う色
  ```
- **プロンプトに明示的なマーカーを入れる**（`🐳`, `[DEV]`, ホスト名常時表示など）
- **VSCode 側でターミナル背景色も変える**
  ```json
  // .vscode/settings.json
  "workbench.colorCustomizations": {
    "terminal.background": "#1a0a1a"
  }
  ```

複数のシグナルを重ねて事故を防ぐ。

**公式 Dev Container との衝突**

公式 Dockerfile の `zsh-in-docker` セクション（oh-my-zsh + p10k を入れる）は **削除する**。Zinit ベースの自前設定と共存できないため。履歴永続化（`/commandhistory`）の設定だけは別途維持する。

##### vim

| 項目 | 内容 |
|------|------|
| プラグインマネージャ | **vim-plug**（`autoload/plug.vim` 必須） |
| テンプレート | `template/template.{js,py,sh}`（vim-template 用） |
| プラグイン | 初回 `:PlugInstall` で GitHub から取得 |
| LSP 関連 | `deno` が必要な可能性あり（要検証） |
| Copilot | `Node.js` 必須（公式 Dev Container に入っている） |

devcontainer に同梱が必要なファイル：
- `vimrc`（旧 `dot.vimrc`）
- `autoload/plug.vim`（vim-plug 本体）
- `template/`（テンプレートファイル一式）

公式 Dev Container は `vim` を素のままインストール済み。LSP 等で機能不足なら `vim-gtk3` など機能版に差し替え検討。

##### tmux

| 項目 | 内容 |
|------|------|
| プラグインマネージャ | **TPM（Tmux Plugin Manager）** |
| テーマ | **Dracula** |
| 使用プラグイン | `tmux-plugins/tpm`, `tmux-plugins/tmux-sensible`, `tmux-plugins/tmux-yank`, `tmux-plugins/tmux-copycat`, `dracula/tmux` |
| プラグイン取得 | 初回 `prefix + I`（または `~/.tmux/plugins/tpm/bin/install_plugins`）で GitHub から取得 |
| カスタマイズ | プレフィックスを `C-q` に変更、ペイン移動 `C-o`、マウス有効、Dracula は cpu/ram 表示 |

**ディレクトリ構造（実行時）**

```
~/.tmux/
├── tmux.conf（→ ~/.tmux.conf にシンボリックリンク）
└── plugins/
    ├── tpm/                 # TPM 本体
    ├── tmux-sensible/       # TPM が install_plugins で取得
    ├── tmux-yank/           # 同上
    ├── tmux-copycat/        # 同上
    └── tmux/                # dracula/tmux
```

`tmux.conf` の最終行 `run '~/.tmux/plugins/tpm/tpm'` で TPM が起動し、`set -g @plugin '...'` で宣言されたプラグインを管理する。

**devcontainer 用にコピーする際の方針**

- 設定ファイル（`dot.tmux.conf`）だけを `config/tmux/` に置く
- TPM はリポジトリに含めず、`init-tmux.sh` で `git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm` する
- 他のプラグインは TPM の `install_plugins` スクリプトで取得（自動 or 手動は要検討）

理由：
- devcontainer リポジトリに submodule のネストを持ち込まない
- プラグインのバージョン管理は TPM に任せる
- イメージ再ビルドや `init-tmux.sh` 再実行で常に最新に追従できる

**重要原則：clone 先は `~/` 配下、`/workspace` には絶対 clone しない**

`.devcontainer/` は親プロジェクトに submodule として取り込まれる前提のため、`/workspace`（バインドマウント = ホストの実フォルダ）配下に `git clone` すると、親リポジトリのワーキングツリー内に管理外の git リポジトリが生まれる。これは避ける。

すべてのプラグイン取得は `~/` 配下（コンテナ内の `/home/node/`）に対して行う。ホスト Mac の `~/` とは別物で、Docker コンテナ内の独立したファイルシステム上にある。

| ツール | clone 先 |
|--------|---------|
| TPM | `~/.tmux/plugins/tpm` |
| TPM 管理プラグイン | `~/.tmux/plugins/{plugin名}` |
| Zinit | `~/.local/share/zinit/zinit.git`（zinitrc が自動セットアップ） |
| Zinit 管理プラグイン | `~/.local/share/zinit/plugins/` |
| vim-plug 管理プラグイン | `~/.vim/plugged/` |

#### init-*.sh 各スクリプトの責務

各スクリプトはイメージ内の `/usr/local/bin/` に配置され、`postStartCommand` から呼ばれる。

**init-zsh.sh**
1. `~/.zsh/` を作成し `.devcontainer/config/zsh/` 内のファイルを配置（コピー or シンボリックリンク）
2. `~/.zshrc` を `~/.zsh/zshrc` へのリンクとして作成
3. Zinit のインストール（初回のみ、`zinitrc` 自体に自動インストール処理あり）

**init-vim.sh**
1. `~/.vim/` を作成し `.devcontainer/config/vim/` 内のファイル（`vimrc`, `autoload/`, `template/`）を配置
2. `~/.vimrc` を作成
3. 初回プラグインインストール（`vim +PlugInstall +qall` を 2 回）

**init-tmux.sh**
1. `~/.tmux/` を作成し `.devcontainer/config/tmux/tmux.conf` を配置
2. `~/.tmux/plugins/tpm` を `git clone`
3. `~/.tmux.conf` のシンボリックリンクを作成
4. TPM のプラグインインストール（`~/.tmux/plugins/tpm/bin/install_plugins`）

#### ファイアウォール対応

初回セットアップで GitHub から各種プラグイン・TPM を取得するため、GitHub への通信が必要。`init-firewall.sh` で既に許可済み。追加で必要になる可能性があるドメイン：

```bash
"raw.githubusercontent.com"
"codeload.github.com"
"objects.githubusercontent.com"
```

GitHub の IP レンジ動的取得（`api.github.com/meta`）でカバーされている可能性が高いが、要検証。

---

### 7. データの永続化（Docker ボリューム）

#### 永続化の仕組み

Dev Container 内のホームディレクトリ（`/home/node/`）の内容は、デフォルトでは **コンテナを Rebuild すると消える**。永続化したい場合は `devcontainer.json` の `mounts` で **Docker の名前付きボリューム** をマウントする。

公式 Dev Container は既に 2 つを永続化している：

```json
"mounts": [
  "source=claude-code-bashhistory-${devcontainerId},target=/commandhistory,type=volume",
  "source=claude-code-config-${devcontainerId},target=/home/node/.claude,type=volume"
]
```

#### 物理的な保存場所

OS によって異なるが、**ホストの一般ファイルシステム（`~/Documents` など）には保存されない**ため、ホスト環境を汚染しない。

| OS | 実体の場所 | 直接アクセス |
|----|-----------|------------|
| **macOS** (Docker Desktop) | `~/Library/Containers/com.docker.docker/Data/vms/0/data/docker.raw`（VM のディスクイメージ内） | 不可（VM 内） |
| **Linux** | `/var/lib/docker/volumes/<ボリューム名>/_data/` | 可能（要 sudo） |
| **Windows** (WSL2) | `%LOCALAPPDATA%\Docker\wsl\data\ext4.vhdx` 内 | 不可 |

OS を問わず、`docker volume` コマンドで管理可能：

```bash
docker volume ls                              # 一覧
docker volume inspect <ボリューム名>           # 詳細
docker volume rm <ボリューム名>                # 削除
docker volume prune                           # 未使用を一括削除
```

中身を覗きたい場合（macOS など直接アクセスできない場合）：

```bash
docker run --rm -it -v <ボリューム名>:/data alpine ls -la /data
```

#### バインドマウントとボリュームの違い

| | バインドマウント | 名前付きボリューム |
|---|---|---|
| 例 | `/workspace`（プロジェクトフォルダと同期） | `~/.aws`（Docker 管理領域） |
| 実体 | ホストの実フォルダそのもの | Docker VM 内の管理領域 |
| ホストから見える | **見える・編集できる** | 通常は見えない |
| 用途 | ソースコード共有 | コンテナ間で共有したい状態の保持 |

#### ライフサイクル

| 操作 | ボリュームへの影響 |
|------|------------------|
| コンテナ停止 / 削除 | 残る |
| Dev Container の Rebuild | **残る**（同じ `devcontainerId` なら再マウントされる） |
| `docker volume rm` | 削除される |
| Docker Desktop アンインストール | VM ごと削除される |

#### `${devcontainerId}` のスコープ

ボリューム名に `${devcontainerId}` を含めると、**そのプロジェクトの Dev Container 専用のボリューム**になる。

- 別プロジェクトで同じ `.devcontainer/` を使ってもボリュームは別
- AWS 認証情報などが別プロジェクト間で共有されない（セキュリティ的に良い）
- 各プロジェクトで `aws sso login` をやり直す必要あり

#### 永続化対象の方針

**永続化必須（認証情報・設定）**

| パス | 用途 |
|------|------|
| `~/.claude` | Claude Code の設定・認証（既存） |
| `~/.aws` | SSO トークンキャッシュ + アクセスキー（手動配置時） |
| `/commandhistory` | シェル履歴（既存） |

**永続化推奨（速度メリット）**

| パス | 用途 |
|------|------|
| `~/.tmux/plugins` | TPM 管理プラグイン |
| `~/.local/share/zinit` | Zinit 本体 + 管理プラグイン |
| `~/.vim/plugged` | vim-plug 管理プラグイン |

これらは毎回再取得しても数秒〜十数秒だが、永続化すればコンテナ起動が速くなる。ネットワーク制限環境でのプラグイン取得失敗リスクも回避できる。

**永続化不要**

- `/workspace` 配下のソースコード → バインドマウントで対応済み
- `~/.zsh/`, `~/.vim/autoload/`, `~/.tmux.conf` などの設定ファイル → `init-*.sh` で毎回配置するため

#### トレードオフ

| | 永続化（ボリューム） | 毎回再構築 |
|---|---|---|
| 起動速度 | **速い**（プラグイン取得スキップ） | 遅い（数秒〜十数秒） |
| ディスク使用 | ボリュームが残り続ける | 軽い |
| クリーン状態 | 古いプラグインが残る可能性 | **常にクリーン** |
| ネットワーク制限環境 | 取得失敗の影響を受けない | 失敗するとシェル/エディタが壊れる |
| AI セキュリティ観点 | プラグインがコンテナ間で残る | コンテナごとに完全分離 |

---

## 残課題・要検討

### A. AWS 関連
- `aws sso login --use-device-code` の実際のフローをコンテナ内で動作検証
- `aws login --remote` も同様に動作検証
- マルチプロファイルの `~/.aws/config` サンプルを README に書く

### B. ファイアウォール
- `ip-ranges.json` 取得時のサイズ・パフォーマンス検証
- `ipset` のサイズ上限（デフォルト 65536）に AWS IP レンジが収まることの確認
- AWS 以外のサービス（GitHub・MCP関連）の許可ドメインの最終確認

### C. Claude Code の `~/.claude` ボリュームと `settings.json` の関係
- `/home/node/.claude` はボリュームマウントされるため、Dockerfile での COPY が効かない可能性
- `init-claude.sh` を作って `postStartCommand` で配置する方式に切り替えるか検討
- 既存の `settings.json` を上書きしないよう配慮（ユーザー編集分の保護）

### D. zsh/vim/tmux 設定の元リポジトリとの同期方針
- 元の `h-akira/{zsh,vim,tmux}` から devcontainer 用にコピーした後、どう同期するか
- 元の更新を手動で取り込む（差分を見て選択的に反映）
- 完全に独立させて、devcontainer 用は別物として育てる

### E. ホストとコンテナ取り違え事故防止の徹底
- p10k 色変更に加え、他のシグナル（プロンプト記号、ホスト名表示、VSCode 背景色）をどう組み合わせるか
- push 用ターミナル（ホスト）にも視覚的マーカーを入れるか

### F. プラグイン初回インストールのタイミング
- Zinit プラグイン → 初回シェル起動時に自動
- vim-plug プラグイン → `init-vim.sh` で `vim +PlugInstall +qall` を自動実行する？それとも手動？
- TPM プラグイン → `init-tmux.sh` で `install_plugins` を自動実行する？
- 自動実行するとコンテナ起動が遅くなるが、ユーザー操作が減る。手動なら逆。

### G. devcontainer リポジトリの汎用化
- public か private か（public なら誰でも参考にできる、private なら制約少ない）
- バージョン管理（タグ付け）でプロジェクトごとに固定する？
- プロジェクト固有の上書き機構（例：プロジェクトの `.devcontainer.local.json` をマージ）

---

## 次のステップ

1. **`.devcontainer/` のファイル整備**
   - リポジトリルート直下に `devcontainer.json`, `Dockerfile`, `init-*.sh` を作成
   - `config/` ディレクトリに zsh/vim/tmux/mcp/claude の設定ファイルを配置
   - `references/dot.devcontainer/` の内容をベースに、本要件に合わせて 0 から書き起こす
2. **README.md 作成**
   - submodule として使う側向けのセットアップ手順
3. **動作検証**
   - 自リポジトリ（このプロジェクト）でコンテナ起動 → SSO ログイン・ファイアウォール・MCP・dotfiles の動作確認
4. **別プロジェクトでの検証**
   - 適当なプロジェクトに submodule として取り込んで再検証
