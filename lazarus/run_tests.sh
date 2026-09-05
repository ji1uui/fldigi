#!/bin/sh
# ============================================================================
# run_tests.sh -- 全テストスイートをクリーンビルドして実行する
#
# なぜスクリプトが要るか:
#   fpc は -FE で指定した出力先に .ppu も置く。テストは -FEtest なので
#   コンパイル済みユニットは test/ に溜まる。units/ だけ掃除しても
#   test/*.ppu が残り、ユニットを直したのに古いものでリンクされる。
#   実際にこれで「直したはずのテストが失敗する」「壊したはずなのに通る」
#   という誤った結果を一度出している。
#   スイートごとに中間物を消してからビルドすることで、この取りこぼしを防ぐ。
#
# なぜ検査つきでビルドするか:
#   アプリ側 (forms/DemoModemApp.lpi) は範囲検査・オーバーフロー検査・
#   I/O 検査を有効にしている。試験だけ無効で走らせていると、
#   **配列外アクセスがあっても試験は通り、アプリでだけ落ちる**。
#   実際、有効にして回したら 29 スイート中 4 つが落ちた (SHA-256 と
#   乱数の折り返し演算が未宣言だった)。宣言を入れて全数通してある。
#   -gl は行番号つきの追跡を出す。検査が発火したとき番地だけでは
#   原因に辿り着けない。
# ============================================================================
set -e
cd "$(dirname "$0")"

# -Cr 範囲検査 / -Ci I/O検査 / -Co オーバーフロー検査 / -gl 行番号つき追跡
# / -gh 解放漏れの検出 (heaptrc)。
# アプリ側の .lpi と同じ検査を試験にも課す (上の説明を参照)。
#
# -gh を常時つけているのは、**解放漏れは静かに増える**からである。
# 実測で 3 スイートが漏らしており、うち 2 つは try..finally の欠落
# (この言語で最も事故が多い形) だった。追加費用は 22 秒中 0.8 秒。
FPC_CHECKS="-Crio -gl -gh"

# 解放漏れの許容数。0 が既定で、ここに挙げたものだけ例外にする。
#
# test_adif_full の 1 ブロック (70〜74 バイト) は、
#   - 負荷を増やしても 1 のまま増えない
#   - 試験をすべて外しても残る
#   - 構成部品を個別に取り出すと再現しない
# ところまで追ったが出所を特定できていない。実害は無い (終了時の
# 1 ブロック) ので既知として記録し、**増えたら落ちる**ようにしてある。
leak_baseline() {
  case "$1" in
    test_adif_full) echo 1 ;;
    *) echo 0 ;;
  esac
}

SUITES="test_contestlog test_fftfilt test_filter_switch test_opprofile \
test_robustness test_rtty_cw test_station_adif test_adif_full \
test_modem test_threadsafety test_macro test_rxextract test_evidence test_realtime test_eventbus test_observability \
test_qsomodel test_plugin test_context_memory test_audioring test_capture test_fftshared \
test_cw_tone test_cw_leading test_replay test_psk_varicode test_psk test_spectrum test_waterfall test_regression"

# §18 の突き合わせは他スイートの申告を材料にするので **最後** に走らせる。
# SUITES には入れず、実行段で末尾に足す。
TRACE_SUITE="test_requirements"

# 外部ライブラリを要するスイート (未導入の環境ではリンクできない)
OPTIONAL_SUITES="test_rigcontrol test_portaudio"

clean() {
  rm -f units/*.o units/*.ppu test/*.o test/*.ppu forms/*.o forms/*.ppu
}

build_one() {
  clean
  fpc $FPC_CHECKS -Fuunits -Futest -FEtest -o"$1" "test/$1.lpr" > "/tmp/build_$1.log" 2>&1
}

fail=0
echo "=== ビルド ==="
for t in $SUITES; do
  if build_one "$t"; then
    printf '%-20s OK\n' "$t"
  else
    printf '%-20s ビルド失敗\n' "$t"
    grep -E 'Error|Fatal' "/tmp/build_$t.log" | head -5
    fail=1
  fi
done

if build_one "$TRACE_SUITE"; then
  printf '%-20s OK\n' "$TRACE_SUITE"
else
  printf '%-20s ビルド失敗\n' "$TRACE_SUITE"
  grep -E 'Error|Fatal' "/tmp/build_$TRACE_SUITE.log" | head -5
  fail=1
fi

for t in $OPTIONAL_SUITES; do
  if build_one "$t"; then
    printf '%-20s OK\n' "$t"
    SUITES="$SUITES $t"
  else
    printf '%-20s 省略 (外部ライブラリ未導入)\n' "$t"
  fi
done

clean

# 前回の被覆申告を消す。残しておくと、被覆をやめたスイートの申告が
# 生き続けて「検証済」の嘘を通してしまう。
rm -rf test/coverage

# §18 の突き合わせは材料が揃ってから。末尾に置く。
SUITES="$SUITES $TRACE_SUITE"

echo
echo "=== 実行 ==="
total_ng=0
total_leak=0
for t in $SUITES; do
  if [ ! -x "test/$t" ]; then continue; fi
  # heaptrc は標準エラーへ出すので分けて受ける。
  out=$(./test/"$t" 2>"/tmp/leak_$t.err") && rc=0 || rc=$?
  ng=$(printf '%s' "$out" | grep -c '\[NG\]' || true)
  total_ng=$((total_ng + ng))
  [ "$rc" -ne 0 ] && fail=1

  leaked=$(grep -oE '^[0-9]+ unfreed memory blocks' "/tmp/leak_$t.err" 2>/dev/null \
    | grep -oE '^[0-9]+' || true)
  [ -z "$leaked" ] && leaked=0
  allowed=$(leak_baseline "$t")
  leakmsg=""
  if [ "$leaked" -gt "$allowed" ]; then
    leakmsg=" 解放漏れ ${leaked}件(許容${allowed})"
    total_leak=$((total_leak + leaked - allowed))
    fail=1
  fi

  printf '%-20s rc=%s NG=%s%s  %s\n' "$t" "$rc" "$ng" "$leakmsg" \
    "$(printf '%s' "$out" | tail -1)"
done

echo
if [ "$fail" -eq 0 ] && [ "$total_ng" -eq 0 ] && [ "$total_leak" -eq 0 ]; then
  echo "すべて成功"
else
  if [ "$total_leak" -gt 0 ]; then
    echo "失敗あり (NG 合計 $total_ng / 想定を超える解放漏れ $total_leak 件)"
    echo "  追跡は /tmp/leak_<スイート名>.err を参照"
  else
    echo "失敗あり (NG 合計 $total_ng)"
  fi
  exit 1
fi
