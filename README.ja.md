# kikori 🪓

*git worktree の木こり: 作業セッションごとに worktree を生やし、マージ済みブランチが残したものをまとめて伐る。*

[English README](README.md)

`kikori` は **セッション worktree**（タスクごとの使い捨てチェックアウト。複数の
AI コーディングセッションを並列で走らせるときに特に有効）のライフサイクルを管理する。

- **`kikori start`** — 日付入りブランチ名で `<repo>-worktrees/<branch>` に worktree を
  作り、gitignore された個人ファイルをコピーし、プロジェクトのセットアップフックを実行する。
- **`kikori cleanup`** — PR がマージ済みのローカルブランチ（サーバー側で rebase される
  スタック PR を含む）を見つけ、ブランチ・worktree・紐づくプロジェクトリソース
  （シミュレータ、キャッシュ等）を確認 1 回でまとめて削除する。

プロジェクト固有の処理はすべて設定・フック・**cleaner プラグイン**として注入するため、
コア部分は言語・ツールチェーンに依存しない。

## インストール

```bash
git clone https://github.com/sei-lit/kikori.git ~/.kikori
ln -s ~/.kikori/bin/kikori /usr/local/bin/kikori
```

必要環境: bash 3.2+（macOS 標準の `/bin/bash` で動く）、git 2.31+。
`kikori cleanup` はさらに [gh](https://cli.github.com/) と GitHub リポジトリが必要
（PR 照会は現状 GitHub のみ）。

## `kikori cleanup` の安全性

ブランチは、変更が `origin/<main>` に入っていると**証明できたときだけ**自動削除される。

1. ローカル tip がマージ済み PR の head と一致（base が main の PR のみ）、または
2. ローカル tip が `origin/<main>` から到達可能、または
3. マージ前にサーバー側で rebase + force-push されていた（GitHub のスタック PR）:
   リモートにブランチが無く、tip は push 済みで、独自 merge commit が無く、
   全コミットのパッチが `origin/<main>` 側と同値（`git patch-id --verbatim`）

証明できないものは理由と手動コマンド付きで「要確認」に表示され、`--force` の
ときだけ削除される。未コミット変更のある worktree も `--force` が必要。
判定の失敗はすべて「消さない」方向に倒れる。

オプション:

| フラグ | 効果 |
| --- | --- |
| `--only <targets>` | 対象を絞る: `branches`, `worktrees`, 各 cleaner プラグイン名（カンマ区切り）。例: `--only xcode-simulators,xcodebuildmcp-caches` でシミュレータとキャッシュだけ削除。`--only branches` のとき worktree が付いたままのブランチは理由付きでスキップされる。 |
| `--force` | 要確認の項目も削除する。 |
| `--dry-run` | 一覧のみ表示。削除もプロンプトもしない。 |
| `--yes` | 確認プロンプトを省略する。 |

## 設定

弱い順に: 組み込みデフォルト < `~/.config/kikori/config.sh`（ユーザー） <
`<repo>/.kikori/config.sh`（リポジトリ。`kikori trust` が必要） < 環境変数 < フラグ。

変数とフックの全一覧は [examples/config.sh](examples/config.sh) を参照。

- `kikori_slug <task>` — ブランチスラッグ生成（LLM CLI が使いやすい。スラッグの形を
  していない出力は捨ててタイムスタンプに落とすので安全）
- `kikori_branch_name <slug>` — `YYYYMMDD-<slug>` 命名の上書き
- `kikori_post_create <worktree> <branch> <base>` — worktree 作成後のプロジェクトセットアップ

### セキュリティモデル

設定ファイルは bash として source されるため、コードが実行される。リポジトリ側の
`.kikori/config.sh` は「リポジトリと一緒に届くコード」なので、`kikori trust` で
その内容を信頼するまで読み込まない。ファイルが変わる（pull で変わる場合を含む）と
信頼は無効になる。非対話環境では未信頼の設定はエラーになる（黙ってスキップしない）。

## cleaner プラグイン

プラットフォーム固有のリソース（iOS シミュレータ、ビルドキャッシュ、コンテナ等）は
`<repo>/.kikori/cleaners/` の実行ファイル、または `KIKORI_CLEANERS` で登録した
プラグインが削除する。プラグイン名（basename）はそのまま `--only` の対象名になる。

プロトコル（詳細は英語 README）:

```
<cleaner> plan [--assume-removed <path>]...   # auto/review の TSV を stdout へ
<cleaner> delete [--force]                    # 確定 id を stdin から、結果 TSV を stdout へ
```

- delete フェーズでは必ず再判定する（plan との間に状態が変わりうる）
- 冪等であること（既に消えている id は `skipped`）
- プラグイン間は独立・実行順序は保証しない

同梱の実装例: [xcode-simulators](examples/cleaners/xcode-simulators)
（worktree ごとのシミュレータ削除）、
[xcodebuildmcp-caches](examples/cleaners/xcodebuildmcp-caches)
（XcodeBuildMCP の DerivedData キャッシュ削除）。

## 開発

```bash
tests/run.sh      # 使い捨てリポジトリ + gh スタブで完結。ネットワーク不要
```

## License

[MIT](LICENSE)
