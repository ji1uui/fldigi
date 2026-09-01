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
  編集距離で測る。区間の長さは参照の長さの前後 ASlack 文字まで許す。 }
function MessageCharErrorRate(const AReference, ADecoded: string;
  ASlack: Integer = 8): Double;

{ 上記をまとめて出す。 }
function MeasureErrorRate(const AReference, ADecoded: string;
  ASlack: Integer = 8): TErrorRateResult;

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
  prev, cur: array of Integer;
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
    prev := Copy(cur, 0, Length(cur));
  end;
  Result := prev[Length(B)];
end;

function CharErrorRate(const AReference, ADecoded: string): Double;
begin
  if Length(AReference) = 0 then
  begin
    if Length(ADecoded) = 0 then Exit(0) else Exit(1);
  end;
  Result := LevenshteinDistance(AReference, ADecoded) / Length(AReference);
end;

function MessageCharErrorRate(const AReference, ADecoded: string;
  ASlack: Integer): Double;
var
  refLen, start, len, d, best: Integer;
  lo, hi: Integer;
begin
  if Length(AReference) = 0 then
  begin
    if Length(ADecoded) = 0 then Exit(0) else Exit(1);
  end;
  if Length(ADecoded) = 0 then Exit(1);

  refLen := Length(AReference);
  best := MaxInt;

  lo := refLen - ASlack;
  if lo < 1 then lo := 1;
  hi := refLen + ASlack;
  if hi > Length(ADecoded) then hi := Length(ADecoded);

  { 参照と同じくらいの長さの窓を全位置で試す。復号が短ければ全体を見る。 }
  if hi < lo then
  begin
    best := LevenshteinDistance(AReference, ADecoded);
  end
  else
    for len := lo to hi do
      for start := 1 to Length(ADecoded) - len + 1 do
      begin
        d := LevenshteinDistance(AReference, Copy(ADecoded, start, len));
        if d < best then
        begin
          best := d;
          if best = 0 then
          begin
            Result := 0;
            Exit;
          end;
        end;
      end;

  Result := best / refLen;
end;

function MeasureErrorRate(const AReference, ADecoded: string;
  ASlack: Integer): TErrorRateResult;
var
  refLen, start, len, d, best, bestStart, bestLen: Integer;
  lo, hi, i, k, x: Integer;
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

  { 本文 CER と、そのときの窓を覚えてビット比較に使う。 }
  refLen := Length(AReference);
  best := MaxInt; bestStart := 1; bestLen := 0;
  if (refLen > 0) and (Length(ADecoded) > 0) then
  begin
    lo := refLen - ASlack; if lo < 1 then lo := 1;
    hi := refLen + ASlack; if hi > Length(ADecoded) then hi := Length(ADecoded);
    if hi < lo then
    begin
      best := LevenshteinDistance(AReference, ADecoded);
      bestStart := 1; bestLen := Length(ADecoded);
    end
    else
      for len := lo to hi do
        for start := 1 to Length(ADecoded) - len + 1 do
        begin
          d := LevenshteinDistance(AReference, Copy(ADecoded, start, len));
          if d < best then
          begin
            best := d; bestStart := start; bestLen := len;
            if best = 0 then Break;
          end;
        end;
  end;
  if best = MaxInt then best := refLen;
  Result.MessageDistance := best;
  if refLen = 0 then
    Result.MessageCer := 0
  else
    Result.MessageCer := best / refLen;

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
