# devcontainer

Claude Code（および他のAIコーディングエージェント）を安全に使うための Dev Container 設定。
親プロジェクトから submodule として `.devcontainer/` に取り込んで利用する。

## 特徴

- **ファイアウォール**: ホワイトリスト方式で AWS / GitHub / npm / PyPI / Anthropic API などへの通信のみ許可（ただし IP レンジ単位の許可なので、後述の「ファイアウォール許可の実態と限界」を参照）
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

## ファイアウォール許可の実態と限界

`init-firewall.sh` のホワイトリストは「ドメインを許可している」ように見えるが、
実態は IP アドレス（CIDR レンジ）の許可にすぎない。Linux の iptables / ipset は
L3（ネットワーク層）で動くため、パケットには「宛先 IP」しか書かれておらず、
ドメイン名は判定材料に使えない。`init-firewall.sh` は起動時にドメインを `dig`
して、その時点で得られた IP を ipset に追加しているだけ。

### 何が許可されているか

| 許可元 | 名目上の対象 | 実態 |
|--------|------------|------|
| AWS の全 IP レンジ（`ip-ranges.json`） | `aws sso login`、AWS API 全般、`mcp.context7.com`（CNAME 先が AWS ELB）等 | **AWS 上に誰かが立てた任意のサービス**（他人の EC2、S3 バケット、CloudFront ディストリビューション等）も含まれる |
| GitHub の全 IP レンジ（`api.github.com/meta`） | `github.com`, `githubusercontent.com`, `api.github.com` 等 | GitHub 上の任意のリポジトリ・コンテンツ全部（ただし GitHub の管理下） |
| 個別ドメインの `dig` 結果 | `registry.npmjs.org`, `pypi.org`, `sentry.io` 等 | コンテナ起動時のスナップショットのみ。CDN がローテーションすると外れる（Fastly 配下の `deb.debian.org` は特に影響大）|

### 脅威モデル

本リポジトリの目的は以下に絞られる：

- ✅ AI による **偶発的な** 外部 API 呼び出しやスクレイピングを防ぐ
- ✅ AI が `rm -rf` 等の破壊的操作をホスト側に到達させない
- ✅ ホスト Mac の `~/.ssh` などへのアクセスを物理的に阻止する
- ❌ **悪意を持った AI** が攻撃者の AWS 上のサーバに情報を送るような **意図的な攻撃** の防御は射程外
  - AWS 全 IP を許可している以上、攻撃者が AWS 上に立てた任意の EC2 / S3 / CloudFront に到達可能
  - GitHub 全 IP を許可している以上、攻撃者の GitHub Pages や Gist にも到達可能
- ❌ プロンプトインジェクションで AI を操って情報送信させる攻撃の防御も射程外

これは **「広範な IP レンジ許可」と引き換えに失っている保護**。本リポジトリは
「個人開発者が日常的に AI コーディングエージェントを使う際の偶発的事故を防ぐ」
ことを目的としており、APT（標的型攻撃）レベルの脅威は対象外。

### 真にドメインベースで制限したい場合

実装可能だが、本リポジトリのスコープからは外れる：

- **HTTP プロキシ方式**（Squid, mitmproxy 等を別コンテナで立てる）: SNI / CONNECT
  ホスト名でフィルタ。HTTPS の中身まで見るには MITM 証明書が必要で複雑
- **dnsmasq + ipset 動的連携**: 名前解決時にフックして、許可ドメインに解決された
  IP を動的に ipset へ追加。同一コンテナ内で完結するが設定が複雑
- **eBPF / Cilium**: カーネル機能で「特定プロセス × 特定ドメイン」を制御。過剰

### 将来の改善余地

- AWS の `ip-ranges.json` には `service` フィールド（`S3`, `EC2`, `STS` ...）が
  ある。`AMAZON` 全許可ではなく **使うサービスだけ絞る** ことは技術的に可能。
  ただし「事前に使う AWS サービスを決め打つ」運用負荷とのトレードオフ
- 詳細な未対応項目は `develop/REVIEW.md` に記録している

### SSH アウトバウンド（TCP/22）はブロックしている

公式 Anthropic devcontainer は TCP/22 を無条件で許可しているが、本リポジトリでは
**意図的にブロックしている**。理由：

- 公式の許可ルール（`iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT`）には宛先制限
  （`-d`）も ipset マッチも無く、`dnsmasq + ipset` で組み立てたドメインフィルタを
  完全に迂回できる経路になる
- 本リポジトリの脅威モデル（[`develop/DOMAIN_FILTERING_DESIGN.md`](develop/DOMAIN_FILTERING_DESIGN.md)、
  [`develop/DNS_FILTER_PRIMER.md`](develop/DNS_FILTER_PRIMER.md) 参照）では「IP 直打ち遮断」
  「外部 DNS 経由の脱出遮断」を明示的なゴールにしており、SSH の素通しはこれと矛盾する
- そもそも認証が必要な Git 操作（`git push` / `git fetch` / プライベート repo の
  clone 等）はホスト側で実行する方針（[GitHub の認証](#github-の認証) 節参照）

#### 影響

| 操作 | 可否 | 備考 |
|------|------|------|
| `git clone https://github.com/...`（公開 repo） | ✅ 可 | `github.com` は dnsmasq の許可リストにあり、TCP/443 で完結 |
| `git clone git@github.com:...`（SSH 形式） | ❌ 不可 | TCP/22 が塞がれている |
| `ssh user@somehost` | ❌ 不可 | 同上 |
| `git push` / `git pull` / `gh pr create` | （実施しない） | コンテナ内ではやらない方針 |

公開リポジトリの `git clone` は HTTPS で代替できるため、通常運用では困らない。

#### フォーク（vendor in）後にコンテナ内 SSH が必要になった場合

特定ホストに対してだけ SSH を開けるパッチを当てる例：

```bash
# init-firewall.sh の「7. Default policy + main allow rules.」より前で
# 個別ホストのみに限定して許可する
SSH_ALLOWED_HOST="ssh.example.com"
ssh_ip=$(getent hosts "$SSH_ALLOWED_HOST" | awk '{print $1; exit}')
iptables -A OUTPUT -p tcp --dport 22 -d "$ssh_ip" -j ACCEPT
```

ただしこの方式は起動時の dig スナップショットに依存するため、CDN 配下のホストには
不向き。GitHub の SSH（`github.com` の port 22）に開けたい場合は、`github.com` が
既に dnsmasq の接尾辞許可に含まれているので、`-m set --match-set allowed-domains dst`
を併用する以下の形がよりクリーン：

```bash
iptables -A OUTPUT -p tcp --dport 22 -m set --match-set allowed-domains dst -j ACCEPT
```

これなら DNS 経由で解決された IP（= 許可ドメインの実 IP）に対してのみ SSH が通る。

## コンテナをリセットしたい時

状況に応じて段階的に強くなる手順がある。最も軽いものから試すこと。

### レベル 1: コードの変更を反映するだけ

VSCode コマンドパレット → **「Dev Containers: Rebuild Container」**

- Docker image を再ビルド（Dockerfile / config の変更が反映される）
- named volume は **残る**（`~/.aws`, `~/.claude`, `~/.local/share/nvim` 等は保持）
- ビルドキャッシュは使う

`init-*.sh` の修正、`config/` の編集、Dockerfile の小さな変更などはこれで足りる。

### レベル 2: ビルドキャッシュも捨てる

VSCode コマンドパレット → **「Dev Containers: Rebuild Without Cache and Reopen in Container」**

- キャッシュを使わずに Dockerfile を最初から評価
- `apt install` の更新反映、`curl` で取る外部ファイルの再取得など
- それでも named volume は残る

### レベル 3: 永続化ボリュームも消す（完全リセット）

SSO トークン・Claude Code 設定・シェル履歴・nvim プラグインキャッシュなどが**全部消える**ことに注意。

```bash
# VSCode を閉じてから、ホスト側ターミナルで実行
docker volume ls --format "{{.Name}}" | grep "^devcontainer-" | xargs docker volume rm
```

その後 VSCode で再度「Reopen in Container」。

### レベル 4: コンテナ・イメージ・ボリュームすべて削除

完全にゼロから作り直したい時。`vsc-` プレフィックスは VSCode が devcontainer 用に作るイメージ名のお決まり。

```bash
# このプロジェクトの devcontainer 関連リソースを全部削除
docker ps -a --format "{{.Names}}\t{{.Image}}" | grep "^vsc-" | awk '{print $1}' | xargs -r docker rm -f
docker images --format "{{.Repository}}:{{.Tag}}" | grep "^vsc-" | xargs -r docker rmi -f
docker volume ls --format "{{.Name}}" | grep "^devcontainer-" | xargs -r docker volume rm
```

**注意**: `vsc-*` / `devcontainer-*` で grep しているので、**他プロジェクトの devcontainer リソースも同時に消える**。複数プロジェクトを Dev Container で運用している場合は、grep を絞るか個別に名前指定すること（例: `grep "vsc-myproject"`）。

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

#### `sudo apt install` が `No route to host` で失敗することがある（Fastly CDN の制限）

`deb.debian.org` / `security.debian.org` は Fastly CDN 配下にあり、DNS 問い合わせ
ごとに違う IP を返してくる。`init-firewall.sh` はコンテナ起動時に **5 回 dig** して
できるだけ多くの IP をホワイトリストに入れているが、Fastly は短時間では同じ IP を
返し続ける挙動があるため、起動時のスナップショットですべての IP を拾いきれない
ことがある。その状態で時間が経って `apt install` を打つと、Fastly が別の IP に
ローテーションして「ホワイトリスト外の IP」に解決され、ファイアウォールが REJECT
する（`Could not connect ... No route to host`）。

#### 対処

1. **コンテナを Rebuild する**（最も確実）
   - `init-firewall.sh` が再実行されて、その時点の Fastly IP プールを取り直す
   - ただし数分〜数時間で再びズレる可能性あり

2. **`sudo apt install` を時間を置いて再試行する**
   - 別の Fastly エッジ IP に当たれば通る
   - ただしランダム性に依存

3. **`pypi.org` / `files.pythonhosted.org`（uvx / pip）でも同じ問題は理論上ある**
   - こちらは DNS が複数 IP を一度に返してくれるので 5 回 dig で 4〜5 個拾えており、実害はほぼなし

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
| Deno バージョン | `Dockerfile` の `DENO_VERSION`（denops.vim 用） |
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
