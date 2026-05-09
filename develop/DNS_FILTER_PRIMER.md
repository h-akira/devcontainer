# DNS フィルタ方式 PoC の前提整理（初心者向け）

`develop/DOMAIN_FILTERING_DESIGN.md` で「(B) dnsmasq + ipset 3 段構成」を採用すると
決まったが、実装に入る前に **何が起きるのか・どう設計するのか** を初心者にも
わかる粒度で整理しておく。本ドキュメントは `dns-filter` ブランチでの PoC を
進めるための土台。

---

## 1. 前提知識: コンテナ内の通信は 2 段階

コンテナ内で `curl https://api.github.com` を打った時、内部では 2 段階の通信が
起きている：

```
[1] DNS 解決:
    アプリ → 「api.github.com の IP は何？」
    DNS サーバ → 「140.82.114.6 だよ」
    （UDP の 53 番ポートで通信）

[2] 実際の通信:
    アプリ → 140.82.114.6 の HTTPS ポート（TCP 443）に接続
```

現状の `init-firewall.sh` は **[2] だけ** を ipset で制御している。
ドメイン名は [1] でしか登場しないので、現状の設計では「ドメイン単位の許可」が
本質的に実現できない。

これを **[1] の DNS 解決段階で許可ドメインかどうか判定する** ように変えるのが、
今回の PoC のゴール。

---

## 2. 「dnsmasq」とは何か

**dnsmasq は小さな DNS サーバ**。コンテナ内で立ち上げて、こう設定する：

> 「`api.github.com` を聞かれたら答える。`attacker.com` を聞かれたら『知らない』と返す」

これでアプリは「許可ドメイン以外は名前解決できない」状態になる。

さらに dnsmasq は便利な機能があり、**「解決した IP を ipset に自動追加する」**
こともできる（`ipset=/<domain>/<setname>` ディレクティブ）。これにより：

1. アプリが `api.github.com` を解決依頼
2. dnsmasq が `140.82.114.6` を返す **+ ipset に追加**
3. アプリが `140.82.114.6` に接続
4. iptables: ipset にあるので ACCEPT

---

## 3. 「上流 DNS」とは何か

dnsmasq は IP を自分で「知っている」わけではない。**誰かに聞きに行く必要がある**。
聞きに行く先が「上流 DNS」。

### 選択肢

| 種類 | 例 | 特徴 |
|------|-----|------|
| (α) Docker 埋め込み DNS | `127.0.0.11` | Docker が各コンテナに自動で立ててくれる。**追加設定なしで使える** |
| (β) パブリック DNS | `1.1.1.1` (Cloudflare), `8.8.8.8` (Google) | 安定・高速、ただし iptables で外向き 53 番を許可する必要 |
| (γ) ホストのデフォルト | 通常は (α) | コンテナ起動時の `/etc/resolv.conf` に書かれているもの |

### 採用: (α) Docker 埋め込み DNS

理由：
- **追加設定が要らない**（Docker が用意してくれる）
- 単一コンテナ前提でも問題なく機能する（compose は不要）
- iptables では localhost 周辺（127.0.0.1 と 127.0.0.11）だけ通せばよい
- `init-firewall.sh` の冒頭にすでに「Docker DNS のルールを保存」する仕掛けがある
  ので、そこと連携しやすい

---

## 4. 全体の流れ（採用方針）

### 許可ドメインへの通信

```
[アプリ]
  ↓ "api.github.com を解決して" (UDP 53 → 127.0.0.1)
[dnsmasq] コンテナ内で 127.0.0.1:53 で待機
  ↓ 「許可リストに含まれる」と判定 → 上流に転送
  ↓ "api.github.com を解決して" (UDP 53 → 127.0.0.11)
[Docker 埋め込み DNS]
  ↓ 結果 "140.82.114.6"
[dnsmasq]
  ↓ ipset allowed-domains に 140.82.114.6 を追加
  ↓ アプリに "140.82.114.6" を返す
[アプリ]
  ↓ 140.82.114.6 に接続 (TCP 443)
[iptables]
  ↓ ipset にあるので ACCEPT
[外部の api.github.com]
```

### 許可外ドメインへの通信

```
[アプリ]
  ↓ "attacker.com を解決して"
[dnsmasq]
  ↓ 「許可リストに無い」と判定 → 「知らない」と返す（NXDOMAIN）
[アプリ]
  ↓ 名前解決失敗、通信できない
```

### IP 直打ちでの通信（許可リストに無い IP）

```
[アプリ]
  ↓ 5.6.7.8 に直接接続を試みる（DNS を使わない）
[ipset]
  ↓ 5.6.7.8 は登録されていない（DNS 経由で追加されてない）
[iptables]
  ↓ REJECT
```

### AI が外部 DNS を直接叩こうとした場合

```
[AI が dig @8.8.8.8 attacker.com を実行]
  ↓ UDP 53 を 8.8.8.8 に送ろうとする
[iptables]
  ↓ DNS の dport 53 は 127.0.0.1 と 127.0.0.11 のみ許可、それ以外 REJECT
  ↓ つまり 8.8.8.8 への DNS は通らない
[AI] 名前解決ができないので IP も知れない
```

これで「ドメインベース許可」+「IP 直打ち遮断」+「外部 DNS 経由の脱出遮断」の
3 段構成が成立する。

---

## 5. PoC の設計判断

| # | 判断項目 | 採用 | 理由 |
|---|---------|------|------|
| 1 | dnsmasq の設定方式 | 「許可ドメインのみ上流に問い合わせる、それ以外は知らないと返す」 | 純粋なホワイトリスト方式。`no-resolv` + 許可ドメインだけ `server=/<suffix>/127.0.0.11` で実現 |
| 2 | 上流 DNS | Docker 埋め込み DNS (`127.0.0.11`) | 追加設定不要、単一コンテナで完結 |
| 3 | iptables ルール | DNS は 127.0.0.1 と 127.0.0.11 のみ許可、TCP は ipset 経由 | AI が外部 DNS を直接叩けない |
| 4 | dnsmasq の起動方法 | `init-firewall.sh` の冒頭で起動（バックグラウンド） | 別スクリプト不要、起動順序を一元管理 |

---

## 6. dnsmasq に書くことになる許可ドメイン（接尾辞マッチ）

`develop/DOMAIN_FILTERING_DESIGN.md` で承認済みのリスト：

### 接尾辞マッチ（その下のサブドメイン全部許可）

```
amazonaws.com         # AWS API、SSO、ELB 等。ip-ranges.json 全許可をこれに置き換え
awsapps.com           # AWS SSO ポータル
docs.aws.com          # AWS Documentation MCP（proxy.search.docs.aws.com 等）
github.com            # GitHub 関連
githubusercontent.com # raw, objects 等
anthropic.com         # api.anthropic.com、将来の statsig.anthropic.com 等
claude.com            # Claude Code ログインフロー（platform.claude.com 等）
debian.org            # deb, security, ftp 等
pypi.org
pythonhosted.org      # files.pythonhosted.org
npmjs.org             # registry.npmjs.org
context7.com          # mcp.context7.com も含む
sentry.io
statsig.com
astral.sh             # uv インストール元
```

### 完全ホスト名で絞る（広すぎる接尾辞を避ける）

```
marketplace.visualstudio.com
update.code.visualstudio.com
vscode.blob.core.windows.net
```

理由: `core.windows.net` を接尾辞許可すると Azure 全 Blob ストレージが許可
されてしまうので、完全ホスト名のみに絞る。

---

## 7. 実装作業の段取り（このブランチ `dns-filter` で進める）

1. **Dockerfile** に `dnsmasq` パッケージを追加
2. **`config/dnsmasq/`** に dnsmasq 設定テンプレートを作成
3. **`init-firewall.sh`** を書き換え：
   - 既存の `dig + ipset 静的追加` を削除
   - AWS / GitHub の IP レンジ全許可を削除
   - dnsmasq の起動を冒頭に追加
   - `/etc/resolv.conf` を `nameserver 127.0.0.1` に固定
   - iptables ルールを新方針に変更
4. **しっかり動作確認**:
   - `aws sso login` 動く？
   - `apt install` 動く？（Fastly ローテーションの問題が解決するか）
   - `npm install` 動く？
   - MCP サーバ起動（uvx, npx）動く？
   - 許可外ドメイン（例: `curl https://example.com`）が遮断されるか？
   - 外部 DNS 直叩き（`dig @8.8.8.8 example.com`）が遮断されるか？
5. **問題なければ main にマージ**

---

## 8. 失敗・撤退条件

PoC が以下の状況になったら main へのマージを諦め、現状（IP allowlist 方式）に
戻す:

- 既存の主要ワークフロー（AWS SSO、apt、npm、pip、MCP）のいずれかが動かない
- dnsmasq の設定が複雑すぎて保守困難
- Docker のネットワーク仕様との相性問題で挙動が不安定

戻す場合: `dns-filter` ブランチを削除して main の現状を維持。develop/ の
ドキュメントは「検討した記録」として残す。
