# DevContainer 構成レビュー

レビュー日: 2026-05-04
対象: `b04d363` on `main`（`feat: add bundled config files for zsh, vim, tmux, claude, mcp`）

## 総評

骨格としては Anthropic 公式の devcontainer をベースに、AWS / MCP / dotfiles を追加するという狙いどおりの構成にはなっている。`init-*.sh` をイメージ内 `/usr/local/bin/` に置きボリューム配下のファイルを `postStartCommand` で初期化するという基本方針は妥当で、idempotent に書かれている部分も多い。`config/` を `/opt/devcontainer/config/` に COPY しているため、submodule 経由で導入されたときの `/workspace/.devcontainer/...` パス依存問題は回避できている。

一方で、本気で「AI を隔離してホストや外部サービスに迷惑をかけない」を満たす実装かというと、いくつか深刻な穴が空いている。
最大のものは **(1) ファイアウォールが完全に立ち上がる前に、コンテナの一般プロセス（および AI）はネットワークに自由にアクセスできる**こと、**(2) IPv6 トラフィックは ip6tables を一切いじっていないため `policy ACCEPT` のまま素通し**になり得ること、**(3) `postStartCommand` が `&&` 連結で6スクリプトを直列実行しており、いずれか1個が失敗するとコンテナのセットアップが途中停止する**こと。
加えて、REQUIREMENTS.md で明確に書かれているのにコードに落ちていない項目（p10k の **背景色** 変更、`set -g @plugin 'tmux-plugins/tpm'` の宣言にもかかわらず TPM が tmux サーバーなしで起動しない問題、`aws sso login --use-device-code` のフローを成立させるための `oidc.<region>.amazonaws.com` などの個別許可 — これは ip-ranges.json に含まれるので OK だが「DNS 解決自体は通る前提」になっており実際にそうなっているかが未検証）など、コード/仕様の食い違いも複数ある。

そのまま「他プロジェクトに submodule add してすぐ AI を解き放つ」というレベルには達していない。Critical 項目は本番投入前に必ず潰すこと。High の多くも実害が出る前に直しておくべき。

---

## 全体に対するユーザーの方針メモ

> （ここに全体的な対応方針・優先順位・スコープ外と判断するもの等を自由に書く）

**メモ:**

---

## 各指摘への対応方針

各項目末尾に「**対応方針:**」欄を設けている。次のいずれかの判断を、**何をするか／しないかが明確になる文章**で記入する：

- **修正する**（指摘どおり / 別案で）— 何を直すかを書く。コード片可
- **後回し**（実装は後で行う）— 理由とタイミングを書く
- **対応しない（コード変更なし）** — 理由を書く（公式準拠、スコープ外、実害なし、等）
- **追加調査が必要** — 何を調べる必要があるかを書く

「WontFix」「Defer」のようなラベルだけでは "結局何もしない" が伝わりにくいので、**判断と行動を日本語で明示すること**。

---

## Critical（修正必須・本番投入前にブロッカー）

### 1. ファイアウォールが「コンテナ起動 → 立ち上がるまでの数秒〜十数秒」素通し状態

- **問題**: `postStartCommand` で `init-firewall.sh` を実行する設計のため、コンテナが起動してから iptables ポリシーが DROP に切り替わるまでの間、AI（Claude Code）も含めて **任意の外向き通信が可能**。`init-firewall.sh` は GitHub の meta API と AWS の `ip-ranges.json`（10MB超）と複数ドメインの `dig` を行うため、回線次第で十秒以上かかる。さらに `postStartCommand` は **コンテナ起動の度に毎回**実行されるので、Rebuild 後だけでなく単純な Start 直後にも毎回この穴が空く。
- **再現/根拠**:
  - `devcontainer.json:60` `postStartCommand: "sudo /usr/local/bin/init-firewall.sh && ..."`
  - `init-firewall.sh:8-15` で flush してから許可ドメインを ipset に追加しているので、**スクリプト実行中はむしろデフォルトのまま全通し**に近い。
  - Dev Containers 仕様上、`postStartCommand` はコンテナがアタッチされた**後**に走る（`waitFor: "postStartCommand"` は VSCode 側のアタッチ完了を遅らせるだけで、コンテナ内プロセスやネットワークは動いている）。
- **修正方針**:
  - `Dockerfile` 内で「デフォルト DROP・DNS と localhost のみ許可」という最小ポリシーを `iptables-save` で焼き込み、起動時に自動適用する `iptables-restore` を含む `entrypoint`（または `runArgs` で `--cap-add=NET_ADMIN` の上で `init` プロセスから iptables を発火）にする。
  - もしくは `onCreateCommand` / `updateContentCommand` で先に「すべて DROP」ベースラインを作っておき、`postStartCommand` で広げる方向にする。
  - 簡易策として、`init-firewall.sh` の冒頭で **まず `iptables -P OUTPUT DROP` をかけてから** ipset 構築を進める順序にする（DNS だけ最初に許可しておけば ip-ranges.json の取得も通る）。現状は逆順で、policy DROP が一番最後（154 行目付近）。
- **影響**: AI が起動直後の数秒を狙って任意の外部 API 叩き / データ抜き出しを行えるとすれば、本リポジトリの存在意義がかなり毀損する。
- **ユーザー反論（両論併記）**:
  - Dev Container の `waitFor: "postStartCommand"` により、**VSCode の UI / 統合ターミナルへのアタッチは postStartCommand 完了まで待機**する。Claude Code はユーザーがアタッチ後に手動で起動 → プロンプトを打って初めて動くため、「AI が起動直後の数秒の隙を狙う」シナリオは現実的に発生しない。
  - したがって「AI 隔離」の文脈では実害なし。レビューエージェントはこの仕様を考慮せず最悪ケースで論じたため評価が過剰。
  - ただし以下のリスクは残る（影響度は限定的）：
    1. **dotfiles サプライチェーン攻撃の窓**: `init-vim.sh` の `vim +PlugInstall`、`init-tmux.sh` の TPM clone、zinit plugin 取得などは firewall 起動前に GitHub に fetch しに行く。これらリポジトリが汚染されていると、firewall 起動前に任意コードが許可外ネットワークと通信できる。
    2. `init-firewall.sh` 自体が GitHub meta と AWS ip-ranges.json を取得する間は当然 firewall 未起動。これは正規エンドポイントなので通常問題にならない。
  - 結論として実態は **Medium〜Low** 相当。Critical のままでは対応の優先度を誤る。
  - **公式オリジナルとの照合**: Anthropic 公式の devcontainer も同じ構造（`postStartCommand: "sudo /usr/local/bin/init-firewall.sh"` + `waitFor: "postStartCommand"`）。公式の脅威モデルでもこの設計が許容されていることを示す。
- **対応方針:** **対応しない（コード変更なし）**。理由: (1) `waitFor: "postStartCommand"` により AI が素通しウィンドウを利用するシナリオは実態として発生しない、(2) Anthropic 公式オリジナルと同じ設計であり「公式は疑わない」方針に整合、(3) 残存する dotfiles サプライチェーン攻撃のリスクは本リポジトリのスコープ外。

### 2. IPv6 トラフィックが完全に素通し（ip6tables 未設定）

- **問題**: `init-firewall.sh` は `iptables`（IPv4 only）しか触っていない。`ip6tables` のデフォルトポリシーは `ACCEPT` であり、Docker コンテナで IPv6 が有効な環境（最近の Docker Desktop は条件次第で IPv6 を喋る）では **AI は IPv6 経由で許可リスト外のホストに自由に通信できる**。
- **再現/根拠**:
  - `init-firewall.sh:9-14` `iptables -F / iptables -X / iptables -t nat -F / iptables -t mangle -F` のみ。`ip6tables` への言及ゼロ。
  - `Dockerfile:9-30` で `iptables` パッケージはインストールされているが、`ip6tables` を明示的に `-P OUTPUT DROP` する処理はどこにもない。
- **修正方針**:
  ```bash
  # init-firewall.sh の冒頭付近
  ip6tables -F || true
  ip6tables -X || true
  ip6tables -P INPUT DROP
  ip6tables -P OUTPUT DROP
  ip6tables -P FORWARD DROP
  # ローカル IPv6 とリンクローカルだけは許可
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ```
  もしくは Docker 側で IPv6 を完全に切る（`devcontainer.json` の `runArgs` で `--sysctl net.ipv6.conf.all.disable_ipv6=1` を渡す等）。
- **影響**: 「外向き通信を必要なものだけに制限する」という REQUIREMENTS.md §1 の根本要件を満たしていない。
- **公式オリジナルとの照合**: Anthropic 公式の `init-firewall.sh` も `iptables` のみで `ip6tables` への言及はゼロ。公式準拠の挙動。
- **対応方針:** **修正する**。`devcontainer.json` の `runArgs` に IPv6 を完全無効化する sysctl を 3 つ追加する：
  ```json
  "--sysctl", "net.ipv6.conf.all.disable_ipv6=1",
  "--sysctl", "net.ipv6.conf.default.disable_ipv6=1",
  "--sysctl", "net.ipv6.conf.lo.disable_ipv6=1"
  ```
  カーネルレベルで IPv6 スタックを切るので `ip6tables` の管理が不要になる。副作用は `::1` 専用 bind のアプリが壊れる程度だが、現代の主要ランタイムは IPv4 フォールバックを持つため実害ほぼなし。AWS / GitHub / npm / PyPI / Anthropic API はすべて IPv4 で到達可能。

### 3. `postStartCommand` が `&&` の直列で 6 スクリプトを連結 → 1 個壊れると以降全部スキップ

- **問題**: `devcontainer.json:60` で
  `sudo init-firewall.sh && init-claude.sh && init-zsh.sh && init-vim.sh && init-tmux.sh && init-mcp.sh`
  と連結している。各スクリプトは `set -euo pipefail` で書かれているため、些細なエラー（例: `init-vim.sh` の `vim +PlugInstall` がネットワーク or ロック競合で非ゼロを返す、`init-tmux.sh` の TPM clone が一時的失敗 など）で **MCP の雛形配置（`init-mcp.sh`）まで到達できない**。MCP サーバが起動しない＝Claude Code がまともに使えない、というユーザー体験になる。
- **再現/根拠**:
  - `devcontainer.json:60`
  - `init-vim.sh:28-29` は `|| true` で逃がしているが、コピー処理（13-22 行）は `set -e` で死ぬ。
  - `init-firewall.sh` は最後の verification ステップ（`init-firewall.sh:157-170`）で例外を `exit 1` する。
- **修正方針**:
  - 連結方式をやめ、`postStartCommand` を JSON 配列にして個別に呼ぶ。あるいは集約ラッパースクリプト（例: `/usr/local/bin/init-all.sh`）を作って、firewall 以外は `|| echo "WARN: ..."` で握りつぶす（firewall だけは fail-close を維持）。
  - 例:
    ```json
    "postStartCommand": "sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/init-all-user.sh"
    ```
    `init-all-user.sh` 側で各 init を呼びつつ、firewall 以外は失敗を warn に降格する。
- **影響**: 一時的なネットワーク失敗で「次に重要なはずの MCP セットアップ」が黙ってスキップされ、ユーザーは原因を追えない。
- **公式オリジナルとの照合**: 公式は `postStartCommand` が firewall 1 本のみのためこの問題は発生しない。**本リポジトリで init を増やしたことで初めて生まれた新規問題**。Critical/High の中で唯一、公式に該当しない独自の不具合。
- **対応方針:** **修正する**。`init-all.sh` を新規作成し集約ラッパーとして使う。`devcontainer.json` の `postStartCommand` は `/usr/local/bin/init-all.sh` 単体に変更。
  - 各ステップを `run_step "<name>" "<cmd>"` 形式で順に呼び、失敗したステップ名をログに出して `exit 1`（fail-close）。
  - `&&` 連結より優れる点: どの init で失敗したかが一目で分かる、ログ整形、将来の retry/condition 追加に対応しやすい。
  - ネットワーク fetch 系（`vim +PlugInstall`、TPM `install_plugins`）の warn 級フォールバックは各 init-*.sh 内で個別に管理（C3 のスコープ外）。

### 4. `init-firewall.sh` の verification は「example.com に到達できないこと」と「api.github.com に到達できること」の2件のみ — AWS については一切検証していない

- **問題**: AWS の ip-ranges.json から数千 CIDR を投入する（最重要のはず）が、その経路が実際に開通したかは確かめていない。`api.github.com` への 1 回の curl は通っても、`d-xxxx.awsapps.com` や `oidc.ap-northeast-1.amazonaws.com` の名前解決→疎通は別物。
- **再現/根拠**: `init-firewall.sh:155-170`。AWS 関連の reachability assertion がない。
- **修正方針**:
  ```bash
  # ip-ranges.json 自身は AWS の IP に乗っているので、再取得できれば疎通も取れている
  if ! curl --connect-timeout 5 -s https://ip-ranges.amazonaws.com/ip-ranges.json | jq -e '.prefixes' >/dev/null; then
      echo "ERROR: post-firewall AWS reachability check failed"
      exit 1
  fi
  ```
  あるいは `aws sts get-caller-identity --no-sign-request` を試みる（401 が返れば疎通 OK）。
- **影響**: 実は AWS への通信が許可されていなくても気付けず、ユーザーが `aws sso login` で詰まってから初めて気付く。
- **公式オリジナルとの照合**: 公式の verification も example.com / api.github.com の 2 件のみで AWS 検証はない。本リポジトリで AWS を主要な許可対象に格上げしたことで発生する課題ではあるが、verification の薄さ自体は公式準拠。
- **対応方針:** **修正する**。`init-firewall.sh` の verification 末尾に `sts.amazonaws.com` への TCP/TLS 疎通チェックを追加。`-L` / `-f` を付けず最小限の疎通確認とする（302 などのリダイレクトでも成功扱い）。`sts.amazonaws.com` は AWS CLI / SDK が必ず叩くコアエンドポイントで AWS IP レンジでカバーされる。`ip-ranges.amazonaws.com` は init-firewall.sh 自身が直前に取得しているため検証として弱く、別のドメインに変更した。失敗時は `exit 1`。

### 5. `init-firewall.sh` 失敗時にネットワークが「全閉」のまま放置される

- **問題**: 関連して、`init-firewall.sh` は途中で `exit 1` する箇所が多数あるが（`init-firewall.sh:48, 53, 71, 76, 95, 119, 129, 158, 166`）、**iptables ポリシーが DROP になった後に exit する経路もある**。例: 154 行目で `iptables -P OUTPUT DROP` を打った後、158 行目の verification で example.com に届いてしまった場合の `exit 1`。あるいは 166 行目で GitHub への到達が失敗して exit。**この状態でコンテナは生きているが完全閉鎖**になり、ユーザーが手動で復旧する手段が `sudo iptables -F` を覚えていない限り存在しない。
- **再現/根拠**: `init-firewall.sh:140-170`。
- **修正方針**: 最後の verification を `trap 'iptables -F; iptables -P OUTPUT ACCEPT' ERR` で巻き戻す or 失敗時のリカバリ手順をログに出す。
- **影響**: ネットワーク疎通が壊れたコンテナを抱えたユーザーが、何が起きたか分からないまま再 Build を強いられる。
- **公式オリジナルとの照合**: 公式の verification も同様に `exit 1` で全閉のまま放置する設計。公式準拠の挙動。
- **対応方針:** **対応しない（コード変更なし）**。理由: (1) fail-close は意図どおりの設計で、壊れた状態のまま動かさないこと自体に価値がある、(2) 失敗時はコンテナを Rebuild すれば解消する。永続化ボリューム（`~/.aws` `~/.claude` 等）は残るためコストは低い、(3) 巻き戻し処理（`iptables -F` 等）を入れると壊れたまま全許可になり逆にセキュリティが低下する、(4) 公式準拠。

---

## High（修正強く推奨）

### 6. `init-zsh.sh` は `~/.zshrc` を**毎回上書き**する → ユーザー編集分が消える

- **問題**: `init-zsh.sh:21-23` で `cp -f "${ZSH_SRC}/dot.zshrc" "${HOME}/.zshrc"`。`~/.zsh/zinitrc` などは Zinit 本体が永続化ボリュームにあるが、`~/.zshrc` は home 直下（永続ボリュームではない）なのでコンテナ Rebuild ごとに復元される。**コンテナ起動の度（`postStartCommand` は毎回走る）に上書き** が走るため、ユーザーが `~/.zshrc` に追記した内容が次回起動で消える。
- **再現/根拠**: `init-zsh.sh:14-26` 全部 `cp -f`。
- **修正方針**:
  - 上書き対象は `~/.zshrc`（dot.zshrc）と `~/.p10k.zsh` と `~/.zsh/{zinitrc,bindkeyrc,dircolors}`。これらは「devcontainer の責務として固定」と割り切るならコメントで明示し、ユーザーは `~/.zsh/add.zshrc` で拡張する設計（実際 dot.zshrc:25-27 にその仕組みがある）にしている**はず**だが、`add.zshrc` も `cp -f` で上書きしている（`init-zsh.sh:14-18`）。**`add.zshrc` は initial template の場合だけ配置し、既存があれば残す**べき。
  - `init-mcp.sh` / `init-claude.sh` と同じ「存在すれば触らない」ロジックで揃える。
- **影響**: ユーザーがコンテナ固有の設定を追記しても次回起動で消えるので、`add.zshrc` の存在意義が崩れる。
- **対応方針:**

### 7. p10k の **背景色** がホストと同じまま（要件未達）

- **問題**: REQUIREMENTS.md `441-453` 行目で「ホストとコンテナの取り違え事故防止のため p10k のディレクトリ **背景色** を変える」と明記しているが、`config/zsh/dot.p10k.zsh` には `POWERLEVEL9K_DIR_BACKGROUND` の上書きがなく、`POWERLEVEL9K_DIR_FOREGROUND=5`（マゼンタ系の前景色）に変更しているだけ。背景色は元のサンプル（`POWERLEVEL9K_BACKGROUND=236` =デフォルト）のまま。
- **再現/根拠**:
  - `config/zsh/dot.p10k.zsh:225` `typeset -g POWERLEVEL9K_DIR_FOREGROUND=5`
  - `dot.p10k.zsh:169` `typeset -g POWERLEVEL9K_BACKGROUND=236` （変更なし）
  - REQUIREMENTS.md `442-444` 行が指定する `POWERLEVEL9K_DIR_BACKGROUND=5` が見当たらない。
- **修正方針**: `dot.p10k.zsh` 内のディレクトリセグメントの **背景色** を上書きする。
  ```zsh
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=5  # Magenta
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=255  # White on magenta
  ```
- **影響**: 「ホストの terminal と取り違えて push する事故防止」という要件 6 のキー機能が機能していない。
- **対応方針:**

### 8. TPM の `install_plugins` を非対話シェルから直接呼んでいる → 動かない可能性大

- **問題**: `init-tmux.sh:25-28` で `~/.tmux/plugins/tpm/bin/install_plugins` を直接実行している。TPM の `install_plugins` は **動いている tmux サーバーに対して `tmux send-keys` で操作する**設計のため、tmux サーバーが起動していない環境では何もしないか失敗する（実装に依る）。さらに失敗を `|| true` で握りつぶしている（`init-tmux.sh:27`）ので、ユーザーは「プラグインが入らない」現象に遭遇しても気づけない。
- **再現/根拠**:
  - `init-tmux.sh:25-28`
  - 実 TPM のスクリプト（`tmux-plugins/tpm` リポジトリの `bin/install_plugins`）は `tmux source ~/.tmux.conf` を呼び出すため、tmux サーバが起動していないと no-op になりがち。
  - REQUIREMENTS.md `546` 行目では「`~/.tmux/plugins/tpm/bin/install_plugins`」を呼ぶことになっているが、原典の TPM の README は `prefix + I` を勧めている。
- **修正方針**:
  ```bash
  # 非対話で確実にインストールするには tmux サーバを噛ませる
  tmux new-session -d -s _tpm_install \
       "~/.tmux/plugins/tpm/bin/install_plugins; tmux kill-session -t _tpm_install" \
       2>/dev/null || true
  ```
  または `install_plugins` をやめて TPM 直で `git clone` をループする init-tmux 側で書く。
- **影響**: 初回起動でプラグインが入らず、ユーザーが手動で `prefix + I` を覚える必要がある。
- **対応方針:**

### 9. `init-firewall.sh` が `aggregate` 不在時に黙って動作する／動作しない の判定なし

- **問題**: REQUIREMENTS.md `12 章` で `aggregate` の前提が明示され、Dockerfile でもインストールしている（`Dockerfile:25`）が、aggregate コマンド自体が非ゼロを返したり、入力が空だったりした場合のハンドリングがない。具体的には、`while read cidr; do ... done < <(echo ... | jq ... | aggregate -q)` という構造（`init-firewall.sh:57-64, 81-88`）。`aggregate -q` は問題があると stderr に何か出すだけで、無音で空出力 → ループが回らない、というケースがある。
- **再現/根拠**: `init-firewall.sh:64, 88`。`pipefail` は付いているので途中失敗で exit はするが、`aggregate` が **0 件出力** の正常終了をするケースは検知できない。
- **修正方針**: ループ内で投入した CIDR 件数を集計し、ゼロ件なら fail。
  ```bash
  if [ "$aws_count" -eq 0 ]; then
      echo "ERROR: 0 CIDR ranges added from AWS ip-ranges; aggregate may have failed silently"
      exit 1
  fi
  ```
  GitHub 側にも同じガードを追加する。
- **影響**: 静かに「AWS 0 件しか許可してない」状態で post-startup が完了する事態がありうる。
- **公式オリジナルとの照合**: 公式の GitHub IP 取得（`api.github.com/meta`）も `aggregate -q` を通す同じ構造で件数チェックなし。公式準拠の挙動。
- **対応方針:**

### 10. `init-firewall.sh` の AWS IPv4 件数は `ipset` のデフォルト上限 `65536` をぎりぎり下回る程度

- **問題**: 2026年5月時点の `ip-ranges.json` の IPv4 prefix 数は **約 9000〜10000 件**（aggregate 後）と推定されるが、ipset の `hash:net` は `maxelem` がデフォルト 65536。GitHub の数十件 + AWS の 10000 件程度なら **当面は収まる** が、AWS が急拡大した場合や IPv6 を後で足した場合に上限を超える。これは REQUIREMENTS.md 残課題 B にも明示されている懸念。
- **再現/根拠**: `init-firewall.sh:41` `ipset create allowed-domains hash:net`（maxelem 指定なし）。
- **修正方針**: `ipset create allowed-domains hash:net maxelem 131072` のように倍にしておく。さらに ipset add の戻り値を見る（現状 `2>/dev/null || true` で握りつぶし `init-firewall.sh:86`）。
- **影響**: 数年スパンで突然 AWS の通信が落ちるバグが残る。診断が極めて困難。
- **公式オリジナルとの照合**: 公式も `ipset create allowed-domains hash:net` のみで `maxelem` 指定なし。公式準拠だが、本リポジトリは AWS の数千 CIDR を追加するため公式より上限に近づくのは事実。
- **対応方針:**

### 11. `aggregate` 経由で投入される CIDR は IPv4 のみ — `ipv6_prefix` を捨てている

- **問題**: AWS の `ip-ranges.json` には `ipv6_prefixes[]` も含まれるが `init-firewall.sh:88` は `.prefixes[].ip_prefix`（IPv4 のみ）しか拾っていない。Critical 2 と関連するが、もし将来 ip6tables を有効にしたとき AWS への IPv6 経路を許可する処理が抜けている。
- **再現/根拠**: `init-firewall.sh:88`。
- **修正方針**: ip6tables 有効化と合わせて、`.ipv6_prefixes[].ipv6_prefix` を別の `ipset create allowed-domains-v6 hash:net family inet6` に投入する。
- **影響**: IPv6 を有効化したときに AWS だけ落ちる。
- **対応方針:**

### 12. `init-mcp.sh` は親プロジェクトの `.gitignore` に `.mcp.json` がない場合の保護がない

- **問題**: `init-mcp.sh` は `/workspace/.mcp.json` を黙って作成する（`init-mcp.sh:21-23`）。親プロジェクトの `.gitignore` に `.mcp.json` が登録されていない場合、ユーザーが Context7 API キーを書いた状態で `git add .` するとそのまま秘密がコミットに乗る。README.md `21` 行目で「`.gitignore` に `.mcp.json` を追加してください」と指示はあるが、コードレベルのフェイルセーフはない。
- **再現/根拠**: `init-mcp.sh:1-23`、README.md `19-21`。
- **修正方針**:
  - `init-mcp.sh` の冒頭で `git check-ignore -q /workspace/.mcp.json` を試して、ignored でなければ警告を出す（fail はしない）。
  - もしくは `init-mcp.sh` 自身が `/workspace/.gitignore` に `.mcp.json` 行を append するモードを `--ensure-gitignore` 等で持たせる（破壊的なので opt-in）。
  ```bash
  if cd /workspace && git rev-parse --git-dir >/dev/null 2>&1; then
      if ! git check-ignore -q .mcp.json 2>/dev/null; then
          echo "WARN: .mcp.json is NOT in .gitignore — your CONTEXT7_API_KEY may be committed!"
      fi
  fi
  ```
- **影響**: API キーが GitHub に push される事故。「外部サービスに迷惑をかけない」要件と直結。
- **対応方針:**

### 13. `init-claude.sh` の配置位置の競合 — `~/.claude` ボリュームと CLAUDE_CONFIG_DIR の意味

- **問題**: `devcontainer.json:46` で `/home/node/.claude` を named volume にマウント、`devcontainer.json:54` で `CLAUDE_CONFIG_DIR=/home/node/.claude` を設定している。`init-claude.sh:13` は `/home/node/.claude/settings.json` に書こうとする。**初回起動では空ボリュームなのでうまくいくが**、ユーザーがすでに Claude Code のグローバル設定（OAuth トークン、ユーザー設定）を入れた状態で `init-claude.sh` が走る場合（`postStartCommand` は毎回走る）、`if [ -f "$TARGET" ]` で逃げる設計なので OK。**ただしユーザーが意図的に `settings.json` を消した場合、こっそり deny ルールが復活する**。これは仕様として明示されていない。
- **再現/根拠**: `init-claude.sh:18-21`。
- **修正方針**: README にこの挙動を明示する。あるいは「マーカーファイル」（例: `/home/node/.claude/.devcontainer-installed`）の有無で判定し、削除されたかどうかを区別する。
- **影響**: 軽微だが、ユーザーが「Claude Code の deny を一時的に外したい」と思って消したら次回起動で復活してハマる。
- **対応方針:**

### 14. AWS CLI のインストール後にチェックサム検証なし

- **問題**: `Dockerfile:62-71` で AWS CLI v2 を curl して unzip して install。GPG 署名検証（`awscli-exe-linux-x86_64-2.34.41.zip.sig`）を一切しない。供給チェーン攻撃の余地。
- **再現/根拠**: `Dockerfile:60-71`。
- **修正方針**: AWS が提供する PGP 公開鍵で署名を検証するステップを追加。Anthropic 公式テンプレートには無いが、submodule で多数のプロジェクトに行き渡る前提を考えると重要。
- **影響**: AWS の公式配布元が侵害されるリスクは低いが、ゼロではない。
- **対応方針:**

### 15. `astral.sh` は許可されているが、`uv` 自体の install 時はそこを叩く（Dockerfile build 時）

- **問題**: `Dockerfile:77` で `curl -LsSf https://astral.sh/uv/install.sh | sh` を Dockerfile ビルド時に実行している。これは build 時なのでホストの DNS とネットワークを使うため動く。一方、`init-firewall.sh:108` で `astral.sh` を許可している（おそらく runtime で `uv self update` などのため）が、`uv self update` を AI に走らせる必然性は薄い。**むしろ `uvx` で MCP サーバを起動する都度 `pypi.org` / `files.pythonhosted.org` を叩くほうが本筋**。`astral.sh` 許可は不要かもしれない。
- **再現/根拠**: `init-firewall.sh:108`。
- **修正方針**: `astral.sh` が runtime に必要かを再検証して、不要なら削る。許可ドメインはミニマムにすべき。
- **影響**: 実害は小さいが、許可リストをミニマルに保つ規律が崩れている。
- **対応方針:**

### 16. `init-firewall.sh` で許可しているドメインに **Anthropic 関連の主要エンドポイント不足**の可能性

- **問題**: `api.anthropic.com` のみで、Claude Code が裏で叩く可能性のある他のエンドポイント（`console.anthropic.com`、ログ送信用の `claude.ai/api/...` 等）は未許可。Anthropic の Sentry / Statsig は明示しているが、Claude Code の OAuth フローや version check で別ドメインを使う可能性がある。
- **再現/根拠**: `init-firewall.sh:94-97`。
- **修正方針**: Claude Code の起動 → ログイン → コード実行を一通り通して、`tcpdump`/`iptables -L -v` でブロックされた宛先を観測し、許可リストに追加する。
- **影響**: Claude Code が一部機能で詰まる可能性。
- **対応方針:**

---

## Medium（直したほうがよい / 要検討）

### 17. `Dockerfile:48` で `/home/node/.aws` を Docker イメージ内にあらかじめ作っている → ボリュームに上書きされる

- **問題**: イメージ内で `mkdir /home/node/.aws && chown node` しているが、`devcontainer.json:47` でその上に空ボリュームをマウントするため、イメージ内に作ったディレクトリ・パーミッションは **ボリュームに置き換わる**（マスクされる）。実害は小さいが「やる意味がない」処理。`/home/node/.claude` も同じ。
- **再現/根拠**: `Dockerfile:48-49`、`devcontainer.json:46-47`。
- **修正方針**: イメージ側 `mkdir` を削除し、ボリュームマウント直後の owner は Docker が自動でやる（`remoteUser: node`）。
- **影響**: 動作はするが意図が伝わりにくい / 不要なレイヤを増やしている。
- **対応方針:**

### 18. ボリュームマウント先が `init-tmux.sh` で `mkdir -p` 済みでないと clone 先のオーナーが変わる可能性

- **問題**: `devcontainer.json:50` で `~/.tmux/plugins` を named volume にマウントするが、`Dockerfile` では `~/.tmux/` は作っていない。Docker は親ディレクトリ `/home/node/.tmux/` をマウント時に root 所有で作る可能性があり、`init-tmux.sh:11` の `mkdir -p` が EACCES で失敗するシナリオがある。実装上は volume の target 自体（`/home/node/.tmux/plugins`）は `node:node` で作られる（Docker は volume の owner をルートディレクトリの owner に合わせる仕様）が、その親 `/home/node/.tmux/` の owner は環境依存。
- **再現/根拠**: `Dockerfile` 上に `~/.tmux/` を作る記述がない、`init-tmux.sh:11` で `mkdir -p`。
- **修正方針**: Dockerfile で `mkdir -p /home/node/.tmux/plugins && chown -R node:node /home/node/.tmux` を追加する。
- **影響**: 一部 Docker バージョンで `init-tmux.sh` が失敗する可能性。
- **対応方針:**

### 19. `init-vim.sh` が `vim +PlugInstall +qall` を 2 回連続実行する、しかも `>/dev/null 2>&1`

- **問題**: `init-vim.sh:28-29` でログを完全に黙らせ `|| true` で逃がしているので、本当に install できたかどうか分からない。さらに 2 回呼ぶ意義もコメントで「workaround for occasional first-run glitches」と書かれているだけで原因が突き止められていない。
- **再現/根拠**: `init-vim.sh:25-30`。
- **修正方針**: 一度だけ呼んで失敗したらログを残す、もしくは `vim +PlugInstall +PlugClean +qall --not-a-term` のようにエラーが起きたら明示的に raise する。
- **影響**: プラグインがインストールできていない状態でユーザーに引き渡される可能性がゼロではない。
- **対応方針:**

### 20. `init-vim.sh` は `~/.vimrc` も毎回 `cp -f` で上書き（item 6 と同型）

- **問題**: `init-vim.sh:13-15`、`init-vim.sh:22` でユーザー編集分が無視される。
- **再現/根拠**: `init-vim.sh:13-22`。
- **修正方針**: item 6 と同様、初期 template のみ書く方式に変えるか、README で「`~/.vimrc` 直接編集は反映されません。`config/vim/dot.vimrc` を編集してください」と明示。
- **影響**: 軽い混乱要因。
- **対応方針:**

### 21. `init-tmux.sh` の TPM clone が中断された場合のリカバリ機構なし

- **問題**: `init-tmux.sh:19-22` で `~/.tmux/plugins/tpm` がディレクトリとして存在するかどうかだけで判定。中身が空（前回中断で `.git/` だけある等）の場合、`install_plugins` が動かないが clone もスキップされる。
- **再現/根拠**: `init-tmux.sh:19-22`。
- **修正方針**: `[ -d "${TPM_DIR}/.git" ] || git clone ...`、または `[ -x "${TPM_DIR}/bin/install_plugins" ] || (rm -rf "${TPM_DIR}" && git clone ...)`。
- **影響**: ユーザーが手動で `~/.tmux/plugins/tpm` をいじると壊れて回復しない。
- **対応方針:**

### 22. `Dockerfile` の `COPY init-firewall.sh init-zsh.sh ...` は build context が submodule のときに動くが、`/workspace/.devcontainer/` 経由ビルドのときは動く

- **問題**: 親プロジェクトの devcontainer.json は **これ自身のもの** が `/workspace/.devcontainer/devcontainer.json` として読み込まれる。`build.dockerfile: "Dockerfile"` は **devcontainer.json と同じディレクトリ（= `/workspace/.devcontainer/`）を build context にする**ので、`COPY config /opt/devcontainer/config` も `COPY init-*.sh /usr/local/bin/` も `.devcontainer/` 内のパスから解決される。これは正しい設計。**ただし develop/ や references/ も build context に含まれる**ため、`.dockerignore` がないと毎回 10MB+ の references/ をビルダーに送り続ける。
- **再現/根拠**: `Dockerfile:96, 100`。`.dockerignore` ファイルがリポジトリにない（`ls -la` で確認済み）。
- **修正方針**: 以下を含む `.dockerignore` をリポジトリ直下に追加：
  ```
  references/
  develop/
  README.md
  .git/
  ```
- **影響**: ビルドが遅くなる、ビルドキャッシュが破壊されやすい。ただ動作には影響しない。
- **対応方針:**

### 23. submodule として取り込まれる前提だが、submodule update 時の `.devcontainer/develop/` の扱いが未整理

- **問題**: README に書かれていない（リポジトリ構成）。submodule 経由で取り込んだ親プロジェクトの開発者は `/workspace/.devcontainer/develop/REQUIREMENTS.md` を見ても自分のプロジェクトと無関係でノイズ。少なくとも README で「develop/ は本リポジトリの開発用」と明示しているのは可。だが「submodule 取り込み時に develop/ を sparse-checkout で除外する」推奨をどこかに書くべき。
- **再現/根拠**: README.md `78` 行目に一応書いてある（「利用側では無視してよい」）。
- **修正方針**: 軽微。README に sparse-checkout の例を足すと丁寧。
- **影響**: なし。
- **対応方針:**

### 24. `mcp.json.template` の `context7` には `"disabled"` `"autoApprove"` が**ない**

- **問題**: 他の 2 サーバには `"disabled": false, "autoApprove": []` が付いているのに `context7` だけ抜けている。Claude Code の現バージョンが `disabled` を未指定で問題ないかは MCP 仕様次第だが、構文として揃えるべき。
- **再現/根拠**: `config/mcp/mcp.json.template:20-26`。
- **修正方針**: `context7` ブロックにも `"disabled": false, "autoApprove": []` を追加。
- **影響**: 軽微。
- **対応方針:**

### 25. `config/zsh/dot.zshrc:38` の `if (( $+commands[dircolors] ))` は OK だが、`dircolors` 設定ファイルが見つからないときのエラーメッセージがない

- **問題**: `references/zsh/dot.zshrc:39-62` にあった「dircolors not found」分岐や `~/.dircolors` を作る処理が削除されている（コンテナは Linux 確定なので OK だが、`${ZDOTDIR}/dircolors` が無いと `eval` がエラーになる）。`init-zsh.sh:14-18` で `dircolors` をコピーしているのでファイル自体は存在するはず。
- **再現/根拠**: `config/zsh/dot.zshrc:38-43`。
- **修正方針**: `[ -f ${ZDOTDIR}/dircolors ]` でガード。
- **影響**: ファイルが何らかの理由で消えるとログが出るが致命的ではない。
- **対応方針:**

### 26. `config/zsh/zinitrc` の Zinit クローン先 `$HOME/.local/share/zinit` は永続化ボリュームと一致しているが、初回 clone 時にネットワーク権限が要る

- **問題**: zsh の初回起動で `git clone https://github.com/zdharma-continuum/zinit ...` が走る（`zinitrc:5`）。`postStartCommand` の途中で zsh が呼ばれるとは限らないが、ユーザーが VSCode のターミナルを開いた瞬間に走る。**`init-firewall.sh` 後なら GitHub に到達できるので OK**だが、**Critical 1 の問題で「init-firewall.sh より先にユーザーがターミナルを開く」事象は仕様上発生し得る**。タイミング次第では clone が成功するか、firewall 起動完了を待つ必要があるかが不安定。
- **再現/根拠**: `config/zsh/zinitrc:2-8`、`devcontainer.json:60`。
- **修正方針**: Critical 1 を直せば自動解消。
- **影響**: 初回起動で稀に zinit が入らない。
- **対応方針:**

---

## Low（nit、好みの問題）

- `Dockerfile:1` `FROM node:20` はまだサポートされているが、Node.js 20 は 2026年4月で EOL。`FROM node:22` か `node:22-bookworm` 推奨。
- `Dockerfile:9-30` `apt-get install` 一括化されているのは良いが、`man-db` を入れているのに man pages を消す `dpkg --force-confnew` 等の最適化なし。イメージサイズが膨らむ。
- `init-firewall.sh` の冒頭コメント「`set -euo pipefail`」は良いが、`init-zsh.sh` などにも書かれている同じ pragma の効果範囲（chained && だと最後の exit コードしか伝わる）について `postStartCommand` 設計者が意識しているか怪しい。
- `devcontainer.json:55` `POWERLEVEL9K_DISABLE_GITSTATUS=true` を環境変数で渡しているが、`config/zsh/dot.p10k.zsh` 内で改めて設定するほうが明示的。
- `README.md:54-58` で `aws login --remote` を案内しているが、`init-firewall.sh` には `signin.amazonaws.com` 系の特別な記述はない（ip-ranges.json でカバーされる前提だがコメントで一言あったほうが親切）。
- `init-firewall.sh:33` で SSH の outbound（dport 22）を許可しているが、devcontainer 内から SSH で外部に出る要件は QA に出てこない。AI 経由のリバースシェル経路として残っている。`pypi.org` の `git+ssh://` をブロックする方向で考えると消したほうが安全。
- `Dockerfile:43-49` で `/home/node/.aws` ディレクトリ作成と所有者設定があるが、ボリュームでマウントされて消える（item 17 で言及）。
- `init-vim.sh` のテンプレートディレクトリ `template/` を `cp -rf` する時、既存テンプレートの上書き挙動が `cp -rf` の semantic で OK か（同名ファイルがあると上書き、無いものは追加）の確認はしたほうがよい。
- `develop/REQUIREMENTS.md` の `34` 行目に `init-zsh.sh` `init-vim.sh` `init-tmux.sh` `init-mcp.sh` は列挙されているが `init-claude.sh` が無い。実装は追加されたが要件側が古いまま。
- `config/zsh/dot.p10k.zsh` は元の sample からの差分が `DIR_FOREGROUND=5` だけで、9万行近くを丸々コミットしているのはレビュー性が悪い。p10k は別ファイルにユーザー上書きを置く運用にしてもよい。

**Low セクション全体への対応方針:**
（ここに Low 項目をまとめてどう扱うか記入。"全部 Defer / 個別に: ..." 等）

---

## 観察された良い点

- `config/` を `/opt/devcontainer/config` に COPY する設計は、submodule 経由でも `/workspace/.devcontainer/...` パスに依存しない正しい解。`init-claude.sh:14` `init-mcp.sh:8` などすべて `/opt/devcontainer/...` を見ている点で一貫している。
- `init-claude.sh` と `init-mcp.sh` が「既存ファイルがあれば触らない」を貫いているのは、ユーザー編集の保護として正しい設計（item 6 で指摘した zsh/vim 系もこれに揃えるべき）。
- ipset を使った許可リストと `iptables -P OUTPUT DROP` のフェイルクローズ方針は基本に忠実。
- 永続化ボリュームの命名規則（`devcontainer-<purpose>-${devcontainerId}`）が一貫していて、プロジェクト分離の意図が明確。
- `mounts` で `~/.tmux/plugins` `~/.local/share/zinit` `~/.vim/plugged` を分離永続化しているのは要件 §7 に忠実。
- AWS CLI バージョンを ARG で固定、Dockerfile で再現可能ビルドにしている点は要件 §1 §4 を満たす。

---

## 未実装 / 取りこぼし

REQUIREMENTS.md の「残課題」と本文を照合した結果：

- **§残課題 A（AWS）**：`aws sso login --use-device-code` フローを README で案内してはいるが、実コンテナで動作検証された痕跡なし（要件側でも「動作検証」段階）。
- **§残課題 B（ファイアウォール）**：`ip-ranges.json` の **件数検証**が実装に組み込まれていない（item 9 と 10 で指摘）。
- **§残課題 C（Claude Code 設定）**：`init-claude.sh` で対処済み。OK。
- **§残課題 E（取り違え事故防止）**：p10k **背景色**変更が未実装（item 7）。プロンプトの `[DEV]` マーカーは window title だけに付与されている（`config/zsh/add.zshrc:10`）が、プロンプトラインそのものには出ない。VSCode の `terminal.background` 設定は `devcontainer.json` の `customizations.vscode.settings` に入っていない。
- **§残課題 F（プラグイン初回インストール）**：要件側で「自動 or 手動を要検討」とあるが、実装は自動側に倒している（OK）。ただし TPM のところは item 8 のとおり機能していない可能性。
- REQUIREMENTS.md `552-558` 行目にある「`raw.githubusercontent.com`, `codeload.github.com`, `objects.githubusercontent.com` を**要検証**として追加候補に挙げている」点は実装で許可済み（`init-firewall.sh:106-108`）。OK。
- README に書かれている `~/.aws/config` のサンプル（要件 §残課題 A: マルチプロファイル）が **無い**。

**未実装項目への対応方針:**
（取りこぼしのうち、実装する/しないの判断と理由を記入）

---

## 検証すべき動作確認項目

実コンテナを立てたとき、以下を順に確認すべき：

- [ ] **コンテナ起動 → `postStartCommand` 完了までの間、`/usr/bin/curl https://example.com` がブロックされるか**（Critical 1 の検証）。同タイミングで `python -c "import urllib.request; urllib.request.urlopen('https://example.com')"` も。
- [ ] **`ip6 -6 ping ipv6.google.com`、`curl -6 https://ipv6.google.com` が通るかどうか**（Critical 2 の検証）。通るなら IPv6 経路が完全に空いている。
- [ ] **`init-firewall.sh` の途中ステップを `false` に書き換えて exit 1 させた場合、後続の `init-claude.sh` 〜 `init-mcp.sh` が走らないか**（Critical 3 の検証）。
- [ ] **`aws sso login --use-device-code` を実行して、表示される `device.sso.<region>.amazonaws.com` への通信が通るか**（要件 §1 §2 の核）。
- [ ] **`uvx awslabs.cdk-mcp-server@latest --help` が走るか**（pypi.org / files.pythonhosted.org 許可の確認）。
- [ ] **`npx -y @upstash/context7-mcp` が起動するか**（registry.npmjs.org 許可の確認）。
- [ ] **`vim +PlugInstall +qall` が手動でも成功するか、`~/.vim/plugged/` 内にプラグイン群があるか**。
- [ ] **`tmux new-session -d` の中で `~/.tmux/plugins/` を `ls` してプラグイン群があるか**（item 8 の検証）。
- [ ] **`/workspace/.mcp.json` を一度ユーザーが編集 → コンテナ Stop/Start 後、編集内容が残っているか**（init-mcp.sh の冪等性）。
- [ ] **`/home/node/.claude/settings.json` を消した後 Restart して、再生成されるか**（init-claude.sh の挙動）。
- [ ] **`~/.zshrc` にユーザーが追記して Restart したとき、追記分が残っているか**（item 6 の検証）。**おそらく消える**。
- [ ] **ipset 件数を `sudo ipset list allowed-domains | grep -c '^[0-9]'` でカウントし、AWS の数千件 + GitHub の十数件が入っているか**。
- [ ] **`.devcontainer/` を別プロジェクトに submodule add し、その親プロジェクトで Reopen in Container した場合に、本リポジトリ単体での起動と同じ挙動になるか**（submodule 利用シナリオの主目的）。
- [ ] **親プロジェクトの `.gitignore` に `.mcp.json` が無い状態で起動 → ユーザーが API キーを書く → `git status` で見えてしまう挙動の確認**（item 12）。
- [ ] **`POWERLEVEL9K_DIR_BACKGROUND` が実際に変わって見えるか（ホストのターミナルと **背景色**で区別できるか）**（item 7）。
- [ ] **`init-firewall.sh` の verification ステップが失敗した場合（例: GitHub に到達できない）、ユーザーがどう復旧できるか手順の確認**（item 5）。

**動作確認項目への方針:**
（実検証はいつ・どこで行うか。優先度付け等を記入）

