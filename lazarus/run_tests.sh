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
# ============================================================================
set -e
cd "$(dirname "$0")"

SUITES="test_contestlog test_fftfilt test_filter_switch test_opprofile \
test_robustness test_rtty_cw test_station_adif test_adif_full \
test_modem test_threadsafety test_macro test_rxextract test_evidence test_realtime test_eventbus test_observability \
test_qsomodel test_plugin"

# 外部ライブラリを要するスイート (未導入の環境ではリンクできない)
OPTIONAL_SUITES="test_rigcontrol test_portaudio"

clean() {
  rm -f units/*.o units/*.ppu test/*.o test/*.ppu forms/*.o forms/*.ppu
}

build_one() {
  clean
  fpc -Fuunits -Futest -FEtest -o"$1" "test/$1.lpr" > "/tmp/build_$1.log" 2>&1
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

for t in $OPTIONAL_SUITES; do
  if build_one "$t"; then
    printf '%-20s OK\n' "$t"
    SUITES="$SUITES $t"
  else
    printf '%-20s 省略 (外部ライブラリ未導入)\n' "$t"
  fi
done

clean

echo
echo "=== 実行 ==="
total_ng=0
for t in $SUITES; do
  if [ ! -x "test/$t" ]; then continue; fi
  out=$(./test/"$t" 2>&1) && rc=0 || rc=$?
  ng=$(printf '%s' "$out" | grep -c '\[NG\]' || true)
  total_ng=$((total_ng + ng))
  [ "$rc" -ne 0 ] && fail=1
  printf '%-20s rc=%s NG=%s  %s\n' "$t" "$rc" "$ng" \
    "$(printf '%s' "$out" | tail -1)"
done

echo
if [ "$fail" -eq 0 ] && [ "$total_ng" -eq 0 ]; then
  echo "すべて成功"
else
  echo "失敗あり (NG 合計 $total_ng)"
  exit 1
fi
