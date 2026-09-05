# .claude/ — このリポジトリの Skill

`CLAUDE.md` (常時ロード) と、この下の Skill (必要なときだけロード) で構成する。

```
CLAUDE.md                          変わらない事実と禁止事項。常にコンテキストに載る
.claude/
├── check-skill-paths.py           paths グロブの健全性検査
└── skills/
    ├── fldigi-lazarus/            中核。手順 + このリポジトリの規律
    │   └── references/            必要時のみ読む参照文書
    ├── lazarus-radio-dsp/         paths で DSP / モデム / スペクトルに限定
    ├── lazarus-cross-platform/    paths でビルド設定 / OS 境界に限定
    ├── lazarus-data-compat/       paths で schema / 設定 / Plugin に限定
    ├── lazarus-security-privacy/  paths で送信制御 / 認証情報に限定
    └── lazarus-release/           手動呼び出しのみ (/lazarus-release)
```

## なぜ中核 Skill が `lazarus-engineering` ではないのか

**personal skill (`~/.claude/skills/`) が project skill を上書きする。**
利用者が個人用に汎用の `lazarus-engineering` を入れていると、同名の
project skill はそれに隠れて**読まれない**。名前を `fldigi-lazarus` に
分けてあるのはそのためで、汎用版と併存できる。

## paths グロブは壊れても何も言わない

`paths` が 1 件も当たらなくても、当たりすぎても、エラーは出ない。
Skill が黙って発動しない (あるいは無関係な場面で発動する) だけである。

このリポジトリでは特に注意が要る。

- **glob は Linux / macOS で大文字小文字を区別する。**
  小文字の `*modem*` は `ModemDSP.pas` に当たらない。
- **上流の C++ と doxygen の画像が同じ木にある。**
  `**/*config*` のような緩いグロブは 150 件以上そちらに届く。
- glob は **プロジェクトルート相対**。`lazarus/` を明示する。

ファイルを増やしたり名前を変えたりしたら検査する。

```bash
python3 .claude/check-skill-paths.py
```

## 構文の検査

```bash
claude plugin validate .claude/skills
```

frontmatter の構文しか見ない。未知のキーは黙って無視されるので、
**通っても意図どおりに動く保証にはならない**。中身は上の検査と
実際の発動で確かめる。

## 出どころ

外部で作られた 2 つの束を取り込んだもの。

- `lazarus-engineering-skill.zip` … 1 Skill + 12 references
- `lazarus-claude-code-bundle.zip` … 上を 6 Skill に分割し、CLAUDE.md を追加

後者を土台に、このリポジトリ向けに以下を変えてある。

- `paths` を全面的に書き直した (元は実際の構成を見ていない推測値だった)
- 中核 Skill を改名し、personal skill による上書きを避けた
- `CLAUDE.md` に「二つの木」「LCL が無い環境」を書いた
- 中核 Skill にこのリポジトリの規律 (要求トレーサビリティ、反証、
  run_tests.sh、範囲検査、共有サービス) を書いた
- 各専門 Skill に「このリポジトリでの実体」の対応表を足した
- `check-skill-paths.py` を足した
