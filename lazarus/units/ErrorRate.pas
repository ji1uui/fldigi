{ ============================================================================
  ErrorRate.pas

  復号結果と送信内容を突き合わせて誤り率を出す (Baseline v1.1 §17 BER/CER)。

  なぜ専用の単位にするのか
  ----------------------------------------------------------------------------
  「直った」「悪くなった」を手作りの数例で判断していると、直したつもりが
  別の条件を壊していることに気づけない。実際、CW のトーン検出を作り直した
  ときは 25 通り × 8 種の乱数で判断したが、それは「統計的改善」を名乗れる
  精度ではなかった (README §28)。Phase 3 の完了条件は
  **「Baseline Decoder より統計的改善を確認する」**なので、比べる物差しが
  要る。

  二つの CER を出す理由
  ----------------------------------------------------------------------------
  復調器はスケルチを切って走らせると、信号の前後で雑音から文字を作る
  (PSK31 は実測で雑音だけ 20 秒に 85 文字。README §31)。この「ゴミ」を
  どう扱うかで数字の意味が変わる。

  - **全体 CER** は復号された文字列そのものを送信内容と比べる。ゴミも
    誤りとして数える。**運用者が画面で見るものに近い**のはこちら。
  - **本文 CER** は最も一致する区間だけを取り出して比べる。
    **復調そのものの実力**を見るのはこちら。ゴミは門番 (スケルチや
    Confidence) の仕事なので、復調の良し悪しと切り分けたいときに使う。

  片方だけでは判断を誤る。全体 CER だけを見ると、門番を強くしただけで
  「復調が良くなった」ことになる。本文 CER だけを見ると、雑音を撒き
  散らす復調器が咎められない。両方を出して、両方に閾値を置く。

  本文 CER の求め方 (窓探索)
  ----------------------------------------------------------------------------
  「復号文字列の中で参照に最も近い区間」を探す。素朴にやると、窓の長さと
  開始位置を総当たりして毎回編集距離を計算することになり、参照 1134 文字で
  1 回 449 ms かかった。Golden WAV の本来の用途は現実的な長さの交信記録
  なので、これでは指標の計算のほうが復調より重くなる。

  Sellers の近似文字列照合を使えば **1 回の DP で済む**。編集距離の表の
  0 行目をすべて 0 にすると「B のどこから始めてもよい」を表せるので、
  最終行の最小値がそのまま答えになる。同じ入力で 8 ms、56 倍速い。

  総当たりと突き合わせたところ、無作為 4 万組で 330 件 (0.8%) 相違した。
  **すべて Sellers のほうが小さい値**で、復号が参照よりずっと短いときに
  限られる。総当たり側は窓の長さを参照 ±slack に制限していたため、
  短い復号では窓を選べず全体と比べていた。Sellers に slack は要らず、
  定義 (「最も近い区間」) に対してはこちらが正しい。

  ビット誤り率について
  ----------------------------------------------------------------------------
  本来の BER は変調記号の段で測るものだが、いまの Modem API は文字
  (Evidence) の単位でしか結果を出さない。ここで出すのは **届いた文字の
  ビットを比べたもの**で、対応が付いた文字どうしの ASCII を XOR して
  数える。誤り訂正の効き方を見るには足りないが、「1 文字違う」を
  「8 ビットぜんぶ違う」と数えないぶん、CER より細かい。
  何を測っているかを取り違えないよう、名前を CharBitErrorRate にした。
  ============================================================================ }
unit ErrorRate;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math;

type
  { 1 回の測定結果。 }
  TErrorRateResult = record
    RefLength: Integer;      // 送信した文字数
    GotLength: Integer;      // 復号された文字数
    Distance: Integer;       // 編集距離 (置換+挿入+削除)
    Cer: Double;             // 全体 CER = Distance / RefLength
    MessageDistance: Integer;// 最も一致する区間での編集距離
    MessageCer: Double;      // 本文 CER
    BitErrors: Integer;      // 対応が付いた文字のビット違い
    BitsCompared: Integer;
    Ber: Double;             // BitErrors / BitsCompared
    function Describe: string;
  end;

{ 編集距離 (Levenshtein)。置換・挿入・削除を等コスト 1 で数える。 }
function LevenshteinDistance(const A, B: string): Integer;

{ 全体 CER。復号文字列すべてを送信内容と比べる。ゴミも誤りとして数える。
  参照が空なら、復号が空のとき 0、そうでなければ 1 を返す。 }

function CharErrorRate(const AReference, ADecoded: string): Double;

{ 本文 CER。ADecoded の中で AReference に最も近い区間を探し、その区間との
  編集距離で測る。区間の長さに制限は設けない (冒頭「窓探索」を参照)。 }
function MessageCharErrorRate(const AReference, ADecoded: string): Double;

{ 上記をまとめて出す。 }
function MeasureErrorRate(const AReference, ADecoded: string): TErrorRateResult;

type
  { 複数回の試行をまとめた統計。Phase 3 で 2 つの復調戦略を比べるために
    使う。1 回の測定だけで「良くなった」と言えないのは、乱数の巡り合わせ
    で簡単に上下するからである。 }
  TErrorRateStats = record
    Count: Integer;
    Mean: Double;
    StdDev: Double;
    Min: Double;
    Max: Double;
    { 平均の 95% 信頼区間の半幅 (正規近似)。Count が小さいと粗い。 }
    Ci95: Double;
    function Describe: string;
  end;

function SummarizeRates(const ARates: array of Double): TErrorRateStats;

{ A が B より **有意に** 小さいか (誤り率なので小さいほうが良い)。

  対応のある比較を想定している。同じ試行番号どうしが同じ条件 (同じ乱数種・
  同じ雑音) で走っていることが前提で、差の平均が 0 から離れているかを見る。
  対応が付いていない値を渡すと、この判定は意味を持たない。

  ACount が 8 未満のときは常に False を返す。少ない試行で「有意」と
  言わせないためである。 }
function SignificantlyBetter(const AValuesA, AValuesB: array of Double;
  out ADiffMean, ADiffCi95: Double): Boolean;

implementation

{ --- 編集距離 --- }

function LevenshteinDistance(const A, B: string): Integer;
var
  prev, cur, tmp: array of Integer;
  i, j, cost, t: Integer;
begin
  if Length(A) = 0 then Exit(Length(B));
  if Length(B) = 0 then Exit(Length(A));

  { 2 行だけ持つ。長いほうを列にすると行が短くなる。 }
  SetLength(prev, Length(B) + 1);
  SetLength(cur, Length(B) + 1);
  for j := 0 to Length(B) do
    prev[j] := j;

  for i := 1 to Length(A) do
  begin
    cur[0] := i;
    for j := 1 to Length(B) do
    begin
      if A[i] = B[j] then cost := 0 else cost := 1;
      t := prev[j] + 1;                       { 削除 }
      if cur[j - 1] + 1 < t then t := cur[j - 1] + 1;   { 挿入 }
      if prev[j - 1] + cost < t then t := prev[j - 1] + cost;  { 置換 }
      cur[j] := t;
    end;
    { 動的配列は参照型なので、入れ替えれば済む。複製すると 1 行ごとに
      確保が走る (窓探索の内側なので効く)。 }
    tmp := prev; prev := cur; cur := tmp;
  end;
  Result := prev[Length(B)];
end;

{ AReference と、ADecoded の **任意の部分文字列** との最小編集距離。
  一致した区間を AStart (1 起点) と ALen で返す。

  Sellers の近似文字列照合。0 行目を 0 で埋めることで「どこから
  始めてもよい」を表す。経路の開始位置も一緒に運ぶので、区間が分かる
  (ビット比較に使う)。 }
function BestWindowDistance(const AReference, ADecoded: string;
  out AStart, ALen: Integer): Integer;
var
  prev, cur, prevS, curS, tmp: array of Integer;
  i, j, cost, del, ins, sub, best, bestJ: Integer;
begin
  AStart := 1;
  ALen := 0;
  if Length(AReference) = 0 then Exit(0);
  if Length(ADecoded) = 0 then Exit(Length(AReference));

  SetLength(prev, Length(ADecoded) + 1);
  SetLength(cur, Length(ADecoded) + 1);
  SetLength(prevS, Length(ADecoded) + 1);
  SetLength(curS, Length(ADecoded) + 1);

  { 0 行目: どこから始めても費用 0。開始位置は自分自身。 }
  for j := 0 to Length(ADecoded) do
  begin
    prev[j] := 0;
    prevS[j] := j;
  end;

  for i := 1 to Length(AReference) do
  begin
    cur[0] := i;
    curS[0] := 0;
    for j := 1 to Length(ADecoded) do
    begin
      if AReference[i] = ADecoded[j] then cost := 0 else cost := 1;
      del := prev[j] + 1;
      ins := cur[j - 1] + 1;
      sub := prev[j - 1] + cost;
      { 開始位置は選んだ手の出所から引き継ぐ。 }
      if (sub <= del) and (sub <= ins) then
      begin
        cur[j] := sub;
        curS[j] := prevS[j - 1];
      end
      else if del <= ins then
      begin
        cur[j] := del;
        curS[j] := prevS[j];
      end
      else
      begin
        cur[j] := ins;
        curS[j] := curS[j - 1];
      end;
    end;
    tmp := prev; prev := cur; cur := tmp;
    tmp := prevS; prevS := curS; curS := tmp;
  end;

  best := prev[0];
  bestJ := 0;
  for j := 1 to Length(ADecoded) do
    if prev[j] < best then
    begin
      best := prev[j];
      bestJ := j;
    end;

  AStart := prevS[bestJ] + 1;
  ALen := bestJ - prevS[bestJ];
  Result := best;
end;

function CharErrorRate(const AReference, ADecoded: string): Double;
begin
  if Length(AReference) = 0 then
  begin
    if Length(ADecoded) = 0 then Exit(0) else Exit(1);
  end;
  Result := LevenshteinDistance(AReference, ADecoded) / Length(AReference);
end;

function MessageCharErrorRate(const AReference, ADecoded: string): Double;
var
  st, ln: Integer;
begin
  if Length(AReference) = 0 then
  begin
    if Length(ADecoded) = 0 then Exit(0) else Exit(1);
  end;
  Result := BestWindowDistance(AReference, ADecoded, st, ln) / Length(AReference);
end;

function MeasureErrorRate(const AReference, ADecoded: string): TErrorRateResult;
var
  bestStart, bestLen, i, k, x: Integer;
  win: string;
begin
  Result.RefLength := Length(AReference);
  Result.GotLength := Length(ADecoded);
  Result.Distance := LevenshteinDistance(AReference, ADecoded);
  if Result.RefLength = 0 then
  begin
    if Result.GotLength = 0 then Result.Cer := 0 else Result.Cer := 1;
  end
  else
    Result.Cer := Result.Distance / Result.RefLength;

  { 本文 CER と、そのときの区間。窓探索は BestWindowDistance に一本化して
    ある (以前は MessageCharErrorRate と二重に書いていて、片方だけ直すと
    二つの API が違う答えを返す形になっていた)。 }
  Result.MessageDistance := BestWindowDistance(AReference, ADecoded,
    bestStart, bestLen);
  if Result.RefLength = 0 then
  begin
    { 参照が空のときの約束は CharErrorRate と揃える。復号も空なら 0、
      何か出ていれば 1。**以前はここだけ常に 0 を返していて**、
      同じ状況で全体 CER が 1、本文 CER が 0 という食い違いが起きていた
      (窓探索を二重に書いていたことの帰結。試験で見つかった)。 }
    if Result.GotLength = 0 then Result.MessageCer := 0
    else Result.MessageCer := 1;
  end
  else
    Result.MessageCer := Result.MessageDistance / Result.RefLength;

  { 届いた文字のビットを比べる。長さが違う分は比べようがないので、
    重なった分だけを見る (何を測っているかは冒頭の説明を参照)。 }
  Result.BitErrors := 0;
  Result.BitsCompared := 0;
  win := Copy(ADecoded, bestStart, bestLen);
  k := Min(Length(AReference), Length(win));
  for i := 1 to k do
  begin
    x := Ord(AReference[i]) xor Ord(win[i]);
    Inc(Result.BitsCompared, 8);
    while x <> 0 do
    begin
      if (x and 1) <> 0 then Inc(Result.BitErrors);
      x := x shr 1;
    end;
  end;
  if Result.BitsCompared = 0 then
    Result.Ber := 0
  else
    Result.Ber := Result.BitErrors / Result.BitsCompared;
end;

function TErrorRateResult.Describe: string;
begin
  Result := Format('CER %.4f (距離 %d / 参照 %d 文字 / 復号 %d 文字) ' +
    '本文CER %.4f / BER %.4f (%d/%d bit)',
    [Cer, Distance, RefLength, GotLength, MessageCer,
     Ber, BitErrors, BitsCompared]);
end;

{ --- 統計 --- }

function SummarizeRates(const ARates: array of Double): TErrorRateStats;
var
  i: Integer;
  s, ss: Double;
begin
  Result.Count := Length(ARates);
  Result.Mean := 0; Result.StdDev := 0; Result.Ci95 := 0;
  Result.Min := 0; Result.Max := 0;
  if Result.Count = 0 then Exit;

  s := 0;
  Result.Min := ARates[0];
  Result.Max := ARates[0];
  for i := 0 to High(ARates) do
  begin
    s := s + ARates[i];
    if ARates[i] < Result.Min then Result.Min := ARates[i];
    if ARates[i] > Result.Max then Result.Max := ARates[i];
  end;
  Result.Mean := s / Result.Count;

  if Result.Count < 2 then Exit;
  ss := 0;
  for i := 0 to High(ARates) do
    ss := ss + Sqr(ARates[i] - Result.Mean);
  Result.StdDev := Sqrt(ss / (Result.Count - 1));
  { 正規近似。試行数が小さいと粗いので、判定には試行数の下限も課す。 }
  Result.Ci95 := 1.96 * Result.StdDev / Sqrt(Result.Count);
end;

function TErrorRateStats.Describe: string;
begin
  Result := Format('n=%d 平均 %.4f ± %.4f (95%%) / 幅 %.4f..%.4f / σ %.4f',
    [Count, Mean, Ci95, Min, Max, StdDev]);
end;

function SignificantlyBetter(const AValuesA, AValuesB: array of Double;
  out ADiffMean, ADiffCi95: Double): Boolean;
var
  n, i: Integer;
  diffs: array of Double;
  st: TErrorRateStats;
begin
  ADiffMean := 0;
  ADiffCi95 := 0;
  Result := False;

  n := Min(Length(AValuesA), Length(AValuesB));
  { 少ない試行で「有意」と言わせない。 }
  if n < 8 then Exit;

  SetLength(diffs, n);
  for i := 0 to n - 1 do
    diffs[i] := AValuesB[i] - AValuesA[i];   { 正なら A のほうが誤りが少ない }

  st := SummarizeRates(diffs);
  ADiffMean := st.Mean;
  ADiffCi95 := st.Ci95;

  { 差の 95% 信頼区間が 0 をまたがないこと。
    すべての差が 0 のとき (まったく同じ結果) は改善ではない。 }
  Result := (st.Mean > 0) and (st.Mean - st.Ci95 > 0);
end;

end.
