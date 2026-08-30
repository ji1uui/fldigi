# ADR-004: Plugin 互換性は Semantic Versioning + Capability Negotiation で扱う

- 状態: 採用 (Phase 0 / draft)
- 対応する Baseline: v1.1 §11 Extension Platform, §11.1 Plugin API 原則, §19 ADR-004
- 実装: `units/PluginApi.pas`
- 検証: `test/test_plugin.lpr`

Baseline の §19 は ADR-004 の初期方針を
「Semantic Versioning + Capability Negotiation」と一行で書いている。
その一行を実際の型に落とすと何を決めることになるか、を書き留める。

## 決めたこと 1: 0.x の間は MINOR の一致を要求する

`TApiVersion.IsSatisfiedBy` の規則:

| Host API の MAJOR | 判定 |
|---|---|
| 要求と違う | 非互換 |
| 1 以上で一致 | Host の MINOR が要求以上なら満たす |
| 0 で一致 | MINOR が **一致** するときだけ満たす |

SemVer は 0.x を「不安定。MINOR の増加で壊してよい」と定義している。
そこを上位互換として扱うと、draft の間に何を変えても「互換です」と
言えてしまい、SemVer を前提にした意味が無くなる。Phase 5 で
"Stable Plugin API" として 1.0.0 を切るまでは、MINOR を上げるたびに
Plugin 側の更新を要求する。

現在の Host API は **0.1.0** である。

## 決めたこと 2: capability は「提供」「必須」「任意」の三つに分ける

当初は Plugin の申告を Provides / Requires の二つにしていた。これは
実装してみて壊れていることが分かった。`HasCapability` が
「自分が Provides しているか」を返す形になり、**Plugin 自身が知っている
ことを Host に聞く** という無意味な口になっていた。テストがこれを
落として気づいた (詳細は §11.1 節の検証記録)。

正しくは、方向が二つある。

| フィールド | 誰の能力か | 無いとどうなるか |
|---|---|---|
| `Provides` | Plugin ができること | Core が「この Modem は送信できるか」等の判断に使う |
| `Requires` | Host に必須で求めるもの | 1 つでも欠ければ **受け入れない** |
| `Wants` | Host にあれば使うもの | 無くても受け入れる。Plugin が避けて動く |

交渉の結果 `Granted` は **(Requires + Wants) ∩ HostCapabilities** で、
「Plugin が Host から使ってよい機能」である。`TPluginHostContext.HasCapability`
はこれを見る。

`Wants` がこの設計の要点である。§11.1 は
「Capability Negotiation で機能差を扱う」と書いているが、機能差を扱うとは
**無いときに落ちることではなく、無いなりに動けるようにすること** を指す。
`Requires` しか無ければ、Plugin は「必須にして拒否される」か
「諦めて宣言しない」かの二択しかなく、交渉になっていない。

## 決めたこと 3: 知らない capability 名で落とさない

`TPluginCapability` は閉じた列挙にした。Core が意味を知っているものを
型で示すためである。しかし Plugin の申告に知らない名前があっても
受け入れを拒まず、`TPluginDescriptor.UnknownCapabilities` に文字列のまま
残す。

これが無いと、新しい Core 向けに書かれた Plugin が古い Core で
**一切** 動かなくなる。残しておけば「その機能は使えないなりに動く」に
なる。前方互換はここで決まる。

## 決めたこと 4: メッセージの引数は名前つきにする

`TPluginMessage` の引数は位置ではなく名前で引く。位置引数は増やすと
破壊的変更 (MAJOR) になるが、名前つきなら引数の追加は MINOR で済む。
受け側は知らない名前の引数を無視する規約とし、`Get` は知らない名前に
対して例外ではなく `pvNone` を返す。

同名の引数は上書きする。二つ並ぶと受け側で結果が変わってしまうため。

## 決めたこと 5: 外部 Modem Plugin は Test vectors を宣言しないと載らない

§11.1 の「外部 Modem Plugin は Test vectors を必須提供する」を、
交渉の段階で機械的に拒否する規則にした
(`Kind = pkModem` かつ `Origin = poExternal` かつ `pcTestVectors` 無し → 拒否)。

文書に書いただけの規則は守られない。Z-02 Regression Testing に外部
Plugin を統合するには、載る時点で持っていることを強制するしかない。
内蔵 Modem は対象外とした ── Core 自身の回帰試験がその役を果たすためで、
`TPluginOrigin` はこの区別のために置いている。

## Host が現在提供している capability

```
pcSoftMetrics     DecodeEvidence (ADR-002)
pcMultiCandidate  DecodeEvidence の候補列 (ADR-002)
pcTx              TModem の送信経路
pcOfflineQueue    TQsoStore の Revision / Sync (ADR-011)
```

`pcReplay` `pcAutoDetection` `pcCabrillo` 等はまだ無い。実装が追いつくまで
ここに書かない。**空手形を並べない** ── 「あることになっているが動かない」
は、無いより悪い。`Requires` にそれらを挙げた Plugin が今日拒否されるのは
不具合ではなく、正しい動作である。

## 代わりに検討して採らなかった案

**案A: capability を文字列だけで扱う。**
拡張は楽だが、Core 側が意味を型で扱えない。`if HasCapability('supports_tx')`
の綴り間違いがコンパイルを通ってしまう。閉じた列挙 + 未知は文字列、
という併用にしたのはこのため。

**案B: バージョンだけで互換性を決める (capability を持たない)。**
Baseline が両方を挙げているのは、版だけでは「同じ版の Core でもビルド
構成によって使える機能が違う」を表せないからである。実際いま
`HOST_CAPABILITIES` は実装の進み具合で変わる。
