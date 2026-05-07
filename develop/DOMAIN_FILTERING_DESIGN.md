# ドメインベースのファイアウォール設計検討

## 背景・問題設定

現状の `init-firewall.sh` は **iptables + ipset による IP/CIDR ベースのホワイトリスト**で
動いており、これは Anthropic 公式の devcontainer をベースにしている。

しかし運用してわかった問題は 3 種類：

1. **CDN ローテーション問題**（実害発生中）
   - `deb.debian.org` のような Fastly CDN は DNS 問い合わせの度に違う IP を返す
   - 起動時の `dig` で取れる IP は数個 / 1 個に過ぎず、時間が経つと別のエッジ IP に
     切り替わって `apt install` が `No route to host` で失敗する
   - 5 回 dig しても短時間では同じ IP しか返らないことが多く、解決しきれない

2. **広範すぎる IP 許可問題**（README 文書化済み）
   - `ip-ranges.json` で AWS 全 IP を許可しているため、**AWS 上に誰かが立てた任意の
     サービス**（他人の EC2、S3、CloudFront 経由のサイト等）にも到達可能
   - GitHub 全 IP も同様（GitHub Pages、Gist、raw.githubusercontent 等で攻撃者ホスト
     コンテンツに届く）
   - Fastly を将来追加すれば Fastly 顧客の任意のサービス（Reddit、Stripe、NYTimes 等）
     も全部許可されることになる

3. **ドメイン単位の意図と実装の乖離**
   - 設定の意図は「`pypi.org` を許可」「`api.anthropic.com` を許可」のような
     **ドメイン単位**
   - しかし実装は「dig 結果の IP を許可」なので、CDN や IaaS のレンジが含まれた
     瞬間に意図がぼやける

これらをまとめて解決するには **ドメイン名でフィルタリングする方式** に切り替える
必要がある。本ドキュメントはその設計検討。

---

## 目指すゴール

- **ドメイン単位の意図がそのまま機能する**
  - `apt install` 用に Debian リポジトリ群（`deb.debian.org` 等）を許可しても、
    Fastly 配下の他サイト（Reddit など）にはアクセスできない
- **CDN の IP ローテーションに追従**できる（時間経過で IP が変わっても通る）
- **AI 隔離の脅威モデルを強化**
  - 現状は「偶発的迷惑回避」のみ
  - ドメインベースに切り替われば「悪意ある AI が攻撃者の AWS EC2 に通信」も
    ある程度防げる（ホスト名が許可リストに入っていない限り）

## 非ゴール

- HTTPS の中身を見る（MITM 復号する）
- HTTP だけでなく任意プロトコル（SSH, WebSocket バイナリ等）の L7 フィルタ
- APT（標的型）レベルの脅威への耐性

---

## 選択肢

### (A) HTTP プロキシ方式（Squid / mitmproxy 等）

**仕組み**:
- 同コンテナ内 or 別コンテナで HTTP プロキシを起動
- メインコンテナの `HTTP_PROXY` / `HTTPS_PROXY` 環境変数を設定
- 全 HTTP/HTTPS 通信がプロキシ経由になる
- プロキシは CONNECT メソッドのホスト名 / TLS SNI を見てドメインで許可判定
- iptables は「プロキシへの通信のみ許可、それ以外は DROP」のシンプルなルール

**ツール候補**:
- **Squid**: 老舗・実績豊富。設定 (`squid.conf`) は複雑だがドキュメント豊富
- **tinyproxy**: 軽量だがホワイトリスト設定機能が弱い
- **mitmproxy**: Python 製、スクリプトでロジック書ける、TLS 復号も可能（不要だが）
- **3proxy**: 中間。設定が比較的シンプル

**メリット**:
- 真にドメインベースのフィルタが実現できる
- CDN ローテーション問題が完全に解決
- AI が悪意ある外部サービスに到達するリスクが大幅減
- 通信ログが詳細に取れる（デバッグ容易）

**デメリット**:
- アーキテクチャの大幅な変更
- プロキシ非対応のアプリは動かない（多くは対応するが、独自バイナリプロトコル等は不可）
- HTTPS は MITM しないと Host ヘッダが見えない → SNI/CONNECT 時のホスト名のみで判定
- TLS 1.3 + ECH（Encrypted Client Hello）が普及すると SNI も暗号化される（将来課題）
- 別コンテナ運用なら Docker Compose / `runArgs` 連携が必要
- 同コンテナ運用ならプロセス管理（systemd 不要、init-*.sh で起動）が必要

### (B) dnsmasq + ipset 動的連携方式

**仕組み**（完全形は 3 段構成）:

1. 同コンテナ内に dnsmasq を立てる（DNS の前段）
2. dnsmasq に許可ドメインリストを持たせる：
   - 許可ドメインを解決した時 → `ipset=/domain/allowed-domains` で IP を動的追加
   - 許可リストにないドメイン → REFUSED を返す（解決しない）
3. iptables のルール:
   - **DNS (`udp/tcp --dport 53`) は localhost (127.0.0.1) のみ許可、それ以外は REJECT**
   - TCP は ipset `allowed-domains` に含まれる IP のみ許可、それ以外は REJECT

これにより：
- アプリが正規ドメインで通信 → dnsmasq が解決 → ipset 追加 → iptables ACCEPT
- アプリが許可外ドメインで通信 → dnsmasq が REFUSED → 解決失敗
- アプリが IP 直打ちで通信 → ipset に無いので REJECT
- アプリが外部 DNS（8.8.8.8 等）を叩く → 53 番が塞がれているので不可

**メリット**:
- 別コンテナ不要、iptables の基本構造は維持（追加ルール数行）
- アプリ側は無改変（プロキシ環境変数も不要、透過的）
- CDN ローテーション問題が完全解決（時間経過で違う IP が解決されても都度許可）
- **IP 直打ち遮断**：ipset に DNS 経由でしか IP が入らないため、自然に遮断される
- **外部 DNS 経由の脱出も防げる**：DNS 自体を localhost のみに絞れば、AI は
  外部の DNS サーバを使えない → 「ドメイン → IP 対応の漏洩」も防げる
- (A) HTTP プロキシ案より変更範囲が小さい
- iptables の設計と相性が良い（既存の init-firewall.sh の枠組みを活かせる）

**デメリット**:
- dnsmasq の設定がやや複雑
- 起動順序の管理（dnsmasq を init-firewall.sh の中で立てる必要）
- `/etc/resolv.conf` を `nameserver 127.0.0.1` で固定する必要
- Docker のデフォルト DNS（`127.0.0.11` の埋め込みリゾルバ）の挙動に注意
  - Docker は `/etc/resolv.conf` を勝手に上書きすることがあるので、起動時の
    扱いに注意（`--dns=127.0.0.1` を `runArgs` で渡すなど）
- 接尾辞マッチの粒度を意識する必要
  - `ipset=/amazonaws.com/allowed-domains` とすれば `*.amazonaws.com` 全部許可
  - `ipset=/example.com/allowed-domains` も同じく `*.example.com` 全部
  - 厳密に `api.example.com` だけ許可したい場合は別パターン必要
- 残る弱点（理論上）:
  - DNS over HTTPS (DoH) で外部解決を試みる経路 → 結局 DoH サーバの IP が ipset
    に無いので連鎖的に塞がれる
  - 許可済みサービス経由の漏洩（例: 許可されている `pypi.org` の検索に攻撃者
    URL を含めるなど）→ これは IP フィルタの範疇外

### (C) eBPF / Cilium 系の L7 フィルタ

- カーネル機能でドメインベース制御
- **複雑すぎて devcontainer のスコープ外**。検討対象外。

### (D) HTTPS プロキシを別コンテナで（Compose 化）

(A) のうち別コンテナ方式に振り切る案。docker compose 化が必要。

**追加メリット**:
- プロキシのプロセスをメインコンテナと分離できる
- プロキシのログをホストから見やすい
- プロキシが落ちてもメインコンテナの shell は生きる（デバッグしやすい）

**追加デメリット**:
- `devcontainer.json` だけでなく `docker-compose.yml` も必要
- submodule 運用との整合性が崩れる可能性（compose ファイルを親プロジェクト側で
  管理するか、submodule 内に持つかの設計判断が必要）
- 親プロジェクトが既に `docker-compose.yml` を持っている場合の競合

---

## 比較表

| 観点 | 現状 (IP allowlist) | (A) HTTP プロキシ同コンテナ | (B) dnsmasq+ipset 3段 | (D) HTTP プロキシ別コンテナ |
|------|---|---|---|---|
| ドメイン単位の意図 | × | ◎ | ○（接尾辞マッチ） | ◎ |
| CDN ローテーション追従 | × | ◎ | ◎ | ◎ |
| 広範 IP 許可問題の解消 | × | ◎ | ◎ | ◎ |
| 実装複雑度 | 低 | 中 | 中（dnsmasq 設定 + iptables 数行追加） | 中〜高 |
| アプリの透過性 | ◎ | △（プロキシ環境変数必要） | ◎ | △ |
| IP 直打ち通信の遮断 | （許可外なら遮断） | ◎ | ◎（ipset 動的追加 + 外部 DNS 遮断） | ◎ |
| 外部 DNS 経由の脱出遮断 | × | ○ | ◎ | ○ |
| HTTPS の透過 | ◎ | ○（CONNECT 経由） | ◎ | ○ |
| submodule 運用との整合 | ○ | ○ | ○ | △（compose 化） |
| 公式 Anthropic からの逸脱度 | 0 | 大 | 中 | 大 |

---

## 検討の論点

### Q1. 既存の IP allowlist 方式を残すか、置き換えるか

- **(置換)** プロキシ / dnsmasq に置き換え、iptables の役割は最小化（プロキシへの
  通信のみ許可）
- **(併用)** ベースは IP allowlist のまま、特定ドメイン（CDN 配下のもの）だけ
  プロキシ / dnsmasq でカバー
- **(段階移行)** まずは現状維持で、別ブランチで PoC を作って動作検証してから本線に取り込む

### Q2. プロキシなら同コンテナ vs 別コンテナ

- 同コンテナ: シンプル、devcontainer.json で完結
- 別コンテナ: クリーン分離、ただし compose 必要

### Q3. dnsmasq 案と HTTP プロキシ案、どちらが筋がいいか

- **dnsmasq + ipset 3段構成**: 透過的（環境変数不要）、IP 直打ちと外部 DNS 経由
  脱出も塞げる（DNS を localhost のみに絞る前提）。**変更コスト・防御力のバランスが良い**
- **HTTP プロキシ**: 環境変数必要、ただしホワイトリスト精度は最高（ホスト名そのもの
  を見る）。MITM すれば HTTP 中身まで見えるが本リポジトリのスコープ外

### Q4. 既存の許可リストはどう移行するか

現状の許可ドメイン群:
- 公式由来: registry.npmjs.org, api.anthropic.com, sentry.io, statsig.com, marketplace.visualstudio.com, vscode.blob.core.windows.net, update.code.visualstudio.com
- 本リポ追加: deb.debian.org, security.debian.org, pypi.org, files.pythonhosted.org, context7.com, mcp.context7.com, raw.githubusercontent.com, codeload.github.com, objects.githubusercontent.com, astral.sh

これを新方式の許可リストに移行する際、どの単位で書くか：
- **完全ホスト名**: `pypi.org`（サブドメインは別途列挙）
- **接尾辞マッチ**: `.amazonaws.com`（すべてのサブドメイン許可、dnsmasq の標準動作）
- **glob**: `*.awsapps.com`

### Q5. AWS / GitHub の特殊扱いをどうするか

現状は ip-ranges.json / api.github.com/meta から **IP レンジで許可** している。
ドメインベースに変えると：

- **AWS**: `*.amazonaws.com`（およびリージョン別 `*.<region>.amazonaws.com`）と
  `*.awsapps.com`（SSO ポータル）に絞れる。これだけで `aws sso login` も S3 も
  STS も MCP の AWS ELB も全部通る
- **GitHub**: `github.com`, `*.githubusercontent.com`, `api.github.com`,
  `codeload.github.com`, `raw.githubusercontent.com` 等に絞れる
- これにより **「他人の EC2 / S3 / CloudFront に届く」問題が解消する**
  （ただし `*.cloudfront.net` を許可すると依然として広いが、AWS 全 IP よりは狭い）

### Q6. 動作検証コスト

ドメインベースに切り替えた場合：

- 既存の動作（aws sso, npm, pip, apt install, github fetch, MCP 起動）が全部
  通ることを確認する必要
- 今まで「広い IP 許可」のおかげで偶然動いていたものが落ちる可能性
- 検証フェーズが必要

---

## 提案する進め方

### フェーズ 1: PoC 構築

別ブランチ（例: `feat/domain-filter-poc`）を切って：

1. **(B) dnsmasq + ipset 3段構成** を最初に試す（同コンテナで完結、移行コスト低い、
   防御力も IP 直打ち・外部 DNS 脱出を含めて高い）
2. (B) で実装上の問題が露呈したら **(A) HTTP プロキシ同コンテナ**（より精度高いが
   アプリ側のプロキシ環境変数が必要）
3. それでも不足なら **(D) 別コンテナ**（compose 化が伴う）

### フェーズ 2: 検証

- 既存の主要ワークフロー全部動くか確認
- 特に AWS SSO ログイン、apt install、MCP 起動

### フェーズ 3: マージ判断

- 動作が同等以上で、許可範囲が狭まっていれば本線取り込み
- 問題があれば現状（IP allowlist）にロールバック

---

## 次のアクション（ユーザーに決めてほしいこと）

1. **方針 A/B/D のどれを優先 PoC 対象とするか**
2. **PoC は別ブランチ or main 上で進めるか**
3. **検証範囲をどう定義するか**（最低限通すべきワークフロー）
4. **撤退条件**（PoC が失敗した場合に戻す閾値）

---

## 参考資料

- Squid 公式: https://www.squid-cache.org/
- mitmproxy: https://mitmproxy.org/
- dnsmasq の `ipset=` ドキュメント: `man dnsmasq` の `--ipset` セクション
- Cilium L7 ポリシー: https://docs.cilium.io/en/stable/security/network/proxy/
- Anthropic 公式 devcontainer: `references/dot.devcontainer/init-firewall.sh`
