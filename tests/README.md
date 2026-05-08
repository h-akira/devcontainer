# tests/

devcontainer の受け入れテスト。

実行方法は 2 通り：

1. **VSCode で現在開いているコンテナの中で実行**（手動・即席）— `firewall.sh` を参照。
   ちょっとした動作確認向き。
2. **新規の使い捨てコンテナを立てて実行**（自動・隔離）— `run-isolated.sh` を参照。
   `init-firewall.sh` / `dnsmasq.conf` / `Dockerfile` などを変更したあと、作業中のコンテナを汚さずにクリーンな状態で検証したいときに使う。

## firewall.sh

DNS フィルタ方式ファイアウォールのエンドツーエンド検証と、同梱ツール群のインストール確認をまとめたスクリプト。

```bash
sudo /workspace/.devcontainer/tests/firewall.sh
# パスワード: devcontainer
```

カバー範囲：

| 区分 | チェック内容（例） |
|------|-------------------|
| プロセス・設定の状態 | dnsmasq が起動している / ipset が存在する / resolv.conf が 127.0.0.1 を指している |
| 許可ドメイン | github / aws / pypi / npm / debian に到達できる |
| 遮断ドメイン | example.com / reddit.com / wikipedia.org が NXDOMAIN になる |
| IP 直打ち攻撃 | `curl https://1.1.1.1` が REJECT される |
| 外部 DNS による脱出 | `dig @8.8.8.8` / `@1.1.1.1` が port 53 で REJECT される |
| ipset の動的追加 | dnsmasq が解決時に IP を追加していること |
| ツール群 | aws / uv / node / nvim / vim symlink / deno / tmux |

各チェックは独立して実行され、失敗しても以降のチェックは続行される。最後にサマリが表示される。終了コードは全パスで 0、1 つでも失敗があれば 1。

## run-isolated.sh

このリポジトリから使い捨てコンテナをビルドし、その中で `firewall.sh` を実行し、終了時にコンテナ・named volume・一時ワークスペースをすべて破棄するスクリプト。VSCode で開いているコンテナには一切触らない。

```bash
./tests/run-isolated.sh
```

テストが失敗したときに、デバッグ用にコンテナを残したい場合：

```bash
KEEP_ON_FAILURE=1 ./tests/run-isolated.sh
# または
./tests/run-isolated.sh --keep-on-failure
# 失敗時にスクリプトが `docker exec -u node -it <id> bash` のヒントを出力する
```

### 必要なツール

| ツール | 用途 | インストール方法 |
|--------|------|----------------|
| `docker` | コンテナランタイム | [Docker Desktop](https://www.docker.com/products/docker-desktop) |
| `devcontainer` | 公式 `@devcontainers/cli` | `npm install -g @devcontainers/cli` |
| `rsync` | リポジトリを使い捨てワークスペースにコピー | macOS / 主要 Linux にプリインストール |

### 内部動作

1. 一時ワークスペース `/tmp/devcontainer-test-XXXXXX/` を `mktemp` で作成。
2. このリポジトリを `<workspace>/.devcontainer/` に `rsync` でコピー。実運用で submodule として取り込まれた状態を再現する。`develop/` / `references/` / `.git/` / `.claude/` は除外。
3. そのワークスペースに対して `devcontainer up` を実行。Docker が新規イメージをビルドしてコンテナを起動する。一時パスがユニークなので `${devcontainerId}` のハッシュ値も新規になり、named volume も完全に新規（既存の VSCode コンテナとはクロストークしない）。
4. コンテナ内で `sudo /workspace/.devcontainer/tests/firewall.sh` を実行。
5. 終了時（成功・失敗・Ctrl-C いずれも）trap でコンテナを削除し、attach されていた全 named volume も削除、一時ワークスペースを `rm -rf`。`KEEP_ON_FAILURE=1` の場合は失敗時のみ手順 5 をスキップしてアーティファクトを残す。

## 実行すべきタイミング

- `init-firewall.sh` / `config/dnsmasq/dnsmasq.conf` / Dockerfile のネットワーク関連箇所 / `devcontainer.json` の `runArgs` または `mounts` を変更したあと（ファイアウォール・DNS 経路に影響しうる変更全般）。
- topic ブランチを main にマージする前。
- 「ネットワークに繋がらない」という報告を受けて調査するとき。
