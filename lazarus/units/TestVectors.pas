{ ============================================================================
  TestVectors.pas

  劣悪な受信条件を再現可能に作る (Baseline v1.1 §14.1 Golden WAV / Test Vector)。

  何のためにあるか
  ----------------------------------------------------------------------------
  復調器を直したとき、直したつもりが別の条件を壊していないかを確かめる
  土台である。Phase 3 の完了条件は「定義済み QSB/QRM/AWGN 条件で
  Baseline Decoder より **統計的改善** を確認する」なので、条件そのものが
  定義されていて、何度でも同じものを作れなければならない。

  Baseline §14.1 が挙げる 10 分類をすべて実装した。

      Clean            劣化なし (基準)
      AWGN             白色雑音
      Extreme QSB      深い緩やかなフェージング (振幅が周期的に沈む)
      Adjacent QRM     隣接周波数の混信
      Impulse noise    突発的な衝撃性雑音
      Frequency drift  時間とともに搬送波がずれる
      Timing mismatch  標本化周波数のわずかな食い違い
      Selective fading 周波数によって沈み方が違うフェージング
      Clipping         振幅の頭打ち (過大入力)
      Silence          無音 (何も出さないことの確認用)

  再現性について (Z-05)
  ----------------------------------------------------------------------------
  system の Random は使わない。**この単位が自前の乱数を持つ。** 理由は
  二つある。

  1. system の Random は他の試験や実装からも回されるので、呼ぶ順番が
     変わると同じ種でも違う列になる。試験を 1 つ足しただけで、無関係の
     試験の数字が動いてしまう。
  2. 生成した波形の内容を種だけで固定できれば、**波形そのものを
     リポジトリに置かなくてよい**。値の並びを検査和で縛れば「Golden」の
     性質 (中身が勝手に変わらない) は保てる。

  S/N の決め方
  ----------------------------------------------------------------------------
  雑音の「振幅」ではなく **dB で指定する**。信号の実効値を実測してから、
  指定の比になるように雑音を作る。振幅で指定すると、信号の大きさが
  変わったときに条件が変わってしまい、モード間の比較もできない。

  ここでいう S/N は **標本化帯域全体 (0〜4 kHz) の広帯域比**である。
  モードごとの占有帯域で正規化した値ではないので、**同じ dB でもモードを
  跨いで難易度は同じではない**。モード間の絶対比較に使うときはこの点に
  注意すること (同一モードの前後比較には問題ない)。
  ============================================================================ }
unit TestVectors;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemTypes, ModemDSP;

type
  { Baseline §14.1 の分類。 }
  TVectorKind = (
    vkClean,
    vkAwgn,
    vkExtremeQsb,
    vkAdjacentQrm,
    vkImpulseNoise,
    vkFrequencyDrift,
    vkTimingMismatch,
    vkSelectiveFading,
    vkClipping,
    vkSilence
  );

  { 劣化の条件。使う欄は種類によって違う。 }
  TVectorSpec = record
    Kind: TVectorKind;
    SnrDb: Double;        // vkAwgn / 他の雑音を伴うもの
    Depth: Double;        // vkExtremeQsb / vkSelectiveFading: 沈みの深さ 0..1
    RateHz: Double;       // vkExtremeQsb / vkSelectiveFading: 沈む速さ
    OffsetHz: Double;     // vkAdjacentQrm: 混信の周波数差
                          // vkFrequencyDrift: 全体でずれる量
    Level: Double;        // vkAdjacentQrm: 混信の強さ (信号比)
                          // vkImpulseNoise: 衝撃の高さ (信号比)
                          // vkClipping: 頭打ちの高さ (信号比)
    PerSecond: Double;    // vkImpulseNoise: 1 秒あたりの回数
    Ppm: Double;          // vkTimingMismatch: 標本化のずれ [ppm]
    { 信号の搬送波周波数。vkAdjacentQrm が「隣」の位置を決めるのに使う。
      0 のままだと混信を絶対周波数 OffsetHz に置くことになり、モードに
      よって離れ方が変わってしまう (CW 700 Hz と PSK 1000 Hz では
      同じ設定でも難易度が違う)。呼び出し側が必ず入れること。 }
    CarrierHz: Double;
    function Describe: string;
  end;

  { 再現可能な乱数。system の Random とは独立に動く。
    xorshift64* を使う。周期が長く、実装が短く、値の並びが処理系に
    依存しない (Z-05 の再現性はここが崩れると成り立たない)。 }
  TVectorRandom = record
  private
    FState: QWord;
  public
    procedure Seed(ASeed: QWord);
    function NextU64: QWord;
    { 0 以上 1 未満 }
    function NextFloat: Double;
    { 平均 0・分散 1 の正規乱数 (Box-Muller)。雑音に使う。 }
    function NextGauss: Double;
  end;

function VectorKindName(AKind: TVectorKind): string;

{ 既定の条件を作る。SnrDb 以外は分類ごとの代表値が入る。 }
function MakeSpec(AKind: TVectorKind; ASnrDb: Double = 20): TVectorSpec;

{ 信号の実効値 (RMS)。 }
function SignalRms(const ASignal: array of Double; ALen: Integer): Double;

{ ASignal に劣化を加えた波形を返す。ASignal は変更しない。
  ASeed が同じなら何度呼んでも同じ結果になる。 }
function ApplyImpairment(const ASignal: array of Double; ALen: Integer;
  const ASpec: TVectorSpec; ASampleRate: Integer;
  ASeed: QWord): TDoubleArray;

{ 波形の周波数を AFromHz から AToHz へ直線的にずらす。
  解析信号にしてから複素回転を掛けるので、片側だけがずれる
  (実信号に cos を掛ける近似と違い、鏡像が出ない)。 }
procedure ShiftFrequencyLinear(var AWave: TDoubleArray; ALen, ASampleRate: Integer;
  AFromHz, AToHz: Double);

{ 波形の検査和。Golden の性質 (中身が勝手に変わらない) を縛るために使う。
  値を 1e-9 の桁で丸めてから畳み込むので、環境差の最下位ビットでは
  変わらないが、意味のある違いは必ず出る。 }
function WaveChecksum(const AWave: array of Double; ALen: Integer): QWord;


implementation

{ --- 乱数 --- }

procedure TVectorRandom.Seed(ASeed: QWord);
begin
  { 0 は xorshift の不動点なので避ける。値そのものに意味はなく、
    0 でなければよい (黄金比の定数の下位ビットを使っている)。
    64 bit の定数は上下に分けて書く。FPC は 2^63 以上の 16 進即値を
    Int64 として読もうとして範囲外だと言うためである。 }
  if ASeed = 0 then
    ASeed := (QWord($9E3779B9) shl 32) or QWord($7F4A7C15);
  FState := ASeed;
end;

{$push}
{$Q-}{$R-}
{ xorshift も FNV も、**折り返しが仕組みの一部**である (乗算の上位ビットを
  捨てることで混ぜている)。アプリ側は検査を有効にしているので、ここが
  宣言されていないと EIntOverflow で落ちる。切るのはこの 2 つの関数だけ。 }

function TVectorRandom.NextU64: QWord;
begin
  { xorshift64* (Vigna)。 }
  FState := FState xor (FState shr 12);
  FState := FState xor (FState shl 25);
  FState := FState xor (FState shr 27);
  Result := FState * QWord($2545F4914F6CDD1D);   { 2685821657736338717 }
end;

{$pop}

function TVectorRandom.NextFloat: Double;
begin
  { 上位 53 bit を使う。 }
  Result := (NextU64 shr 11) * (1.0 / 9007199254740992.0);
end;

function TVectorRandom.NextGauss: Double;
var
  u1, u2: Double;
begin
  { Box-Muller。u1 が 0 になると Ln が定義できないので下限を置く。 }
  u1 := NextFloat;
  if u1 < 1E-300 then u1 := 1E-300;
  u2 := NextFloat;
  Result := Sqrt(-2.0 * Ln(u1)) * Cos(2 * Pi * u2);
end;

{ --- 条件 --- }

function VectorKindName(AKind: TVectorKind): string;
begin
  case AKind of
    vkClean:            Result := 'Clean';
    vkAwgn:             Result := 'AWGN';
    vkExtremeQsb:       Result := 'Extreme QSB';
    vkAdjacentQrm:      Result := 'Adjacent QRM';
    vkImpulseNoise:     Result := 'Impulse noise';
    vkFrequencyDrift:   Result := 'Frequency drift';
    vkTimingMismatch:   Result := 'Timing mismatch';
    vkSelectiveFading:  Result := 'Selective fading';
    vkClipping:         Result := 'Clipping';
    vkSilence:          Result := 'Silence';
  else
    Result := '?';
  end;
end;

function TVectorSpec.Describe: string;
begin
  case Kind of
    vkClean, vkSilence:
      Result := VectorKindName(Kind);
    vkAwgn:
      Result := Format('%s S/N %.1f dB', [VectorKindName(Kind), SnrDb]);
    vkExtremeQsb, vkSelectiveFading:
      Result := Format('%s 深さ %.2f / %.2f Hz / S/N %.1f dB',
        [VectorKindName(Kind), Depth, RateHz, SnrDb]);
    vkAdjacentQrm:
      Result := Format('%s 搬送波%+.0f Hz 強さ %.2f / S/N %.1f dB',
        [VectorKindName(Kind), OffsetHz, Level, SnrDb]);
    vkImpulseNoise:
      Result := Format('%s %.1f 回/秒 高さ %.1f / S/N %.1f dB',
        [VectorKindName(Kind), PerSecond, Level, SnrDb]);
    vkFrequencyDrift:
      Result := Format('%s %+.1f Hz / S/N %.1f dB',
        [VectorKindName(Kind), OffsetHz, SnrDb]);
    vkTimingMismatch:
      Result := Format('%s %.0f ppm / S/N %.1f dB',
        [VectorKindName(Kind), Ppm, SnrDb]);
    vkClipping:
      Result := Format('%s 頭打ち %.2f / S/N %.1f dB',
        [VectorKindName(Kind), Level, SnrDb]);
  else
    Result := VectorKindName(Kind);
  end;
end;

function MakeSpec(AKind: TVectorKind; ASnrDb: Double): TVectorSpec;
begin
  { FillChar を使わない。いまの TVectorSpec は数値と列挙だけなので安全だが、
    string の欄を 1 つ足した瞬間に参照計数を減らさずポインタを潰して漏らす。
    ErrorRate.pas で同じ誤りを踏んで直したので、こちらも揃えておく。 }
  Result.Kind := AKind;
  Result.SnrDb := ASnrDb;
  Result.Depth := 0;
  Result.RateHz := 0;
  Result.OffsetHz := 0;
  Result.Level := 0;
  Result.PerSecond := 0;
  Result.Ppm := 0;
  Result.CarrierHz := 0;
  case AKind of
    vkExtremeQsb:
      begin
        { 深い遅いフェージング。0.2 Hz は 5 秒周期。短点数個ぶんではなく
          文字数個ぶんの時間で沈むので、復調器の追従が試される。 }
        Result.Depth := 0.95;
        Result.RateHz := 0.2;
      end;
    vkSelectiveFading:
      begin
        Result.Depth := 0.9;
        Result.RateHz := 0.3;
      end;
    vkAdjacentQrm:
      begin
        { 隣で誰かが送信している状況。200 Hz 離れで同じくらいの強さ。 }
        Result.OffsetHz := 200;
        Result.Level := 1.0;
      end;
    vkImpulseNoise:
      begin
        { 送電線雑音のような衝撃性雑音。 }
        Result.PerSecond := 20;
        Result.Level := 8.0;
      end;
    vkFrequencyDrift:
      begin
        { 受信中に 0 Hz から 60 Hz までずれる。

          値は測って決めた。20 Hz では CW も RTTY も PSK63 も平気で
          通ってしまい、**RTTY の AFC を切っても結果が変わらなかった**。
          それでは AFC を試したことにならない。

          実測 (0 Hz から N Hz へ直線ドリフト、本文 CER の平均):

              N Hz            0    20    40    60   100   160
              CW20         0.00  0.00  0.00  0.00  0.00  0.00
              RTTY45 AFC入 0.00  0.00  0.00  0.00  0.36  0.86
              RTTY45 AFC切 0.00  0.00  0.00  0.36  0.57  0.79
              PSK31        0.00  0.79  0.79  0.79  0.79  0.79
              PSK63        0.00  0.00  0.86  0.86  0.79  0.79

          60 Hz が AFC の有無で差が出る最初の点である。
          PSK は AFC が無いのでどちらも落ちる (既知の限界)。 }
        Result.OffsetHz := 60;
      end;
    vkTimingMismatch:
      begin
        { 送受のサウンドカードの水晶の食い違い。100 ppm は安物の水準。 }
        Result.Ppm := 100;
      end;
    vkClipping:
      begin
        { 入力過大で頭が潰れる。実効値の 1.5 倍で頭打ち。 }
        Result.Level := 1.5;
      end;
  end;
end;

function SignalRms(const ASignal: array of Double; ALen: Integer): Double;
var
  i: Integer;
  s: Double;
begin
  if ALen <= 0 then Exit(0);
  s := 0;
  for i := 0 to ALen - 1 do
    s := s + ASignal[i] * ASignal[i];
  Result := Sqrt(s / ALen);
end;

{ 指定 S/N になる雑音の実効値を返す。 }
function NoiseRmsFor(ASignalRms, ASnrDb: Double): Double;
begin
  if ASignalRms <= 0 then Exit(0);
  Result := ASignalRms / Power(10.0, ASnrDb / 20.0);
end;

function ApplyImpairment(const ASignal: array of Double; ALen: Integer;
  const ASpec: TVectorSpec; ASampleRate: Integer;
  ASeed: QWord): TDoubleArray;
var
  rnd: TVectorRandom;
  i, j, n, idx: Integer;
  sigRms, noiseRms, env, t, ph, dPh, lim, fracPos, pos, step: Double;
  nextImpulse, meanGap: Double;
begin
  Result := nil;
  rnd.Seed(ASeed);
  sigRms := SignalRms(ASignal, ALen);
  noiseRms := NoiseRmsFor(sigRms, ASpec.SnrDb);

  { Silence だけは入力の中身を使わない。 }
  if ASpec.Kind = vkSilence then
  begin
    SetLength(Result, ALen);
    for i := 0 to ALen - 1 do
      Result[i] := noiseRms * rnd.NextGauss;
    Exit;
  end;

  { Timing mismatch は長さが変わるので先に作る。 }
  if ASpec.Kind = vkTimingMismatch then
  begin
    step := 1.0 + ASpec.Ppm * 1E-6;
    n := Trunc(ALen / step);
    if n < 1 then n := 1;
    SetLength(Result, n);
    for i := 0 to n - 1 do
    begin
      { 線形補間で読み出し位置をずらす。標本化周波数の食い違いは
        「相手の時計が少し速い/遅い」ことなので、読み出しを伸縮させる。 }
      pos := i * step;
      idx := Trunc(pos);
      fracPos := pos - idx;
      if idx + 1 < ALen then
        Result[i] := ASignal[idx] * (1 - fracPos) + ASignal[idx + 1] * fracPos
      else if idx < ALen then
        Result[i] := ASignal[idx]
      else
        Result[i] := 0;
      Result[i] := Result[i] + noiseRms * rnd.NextGauss;
    end;
    Exit;
  end;

  SetLength(Result, ALen);
  for i := 0 to ALen - 1 do
    Result[i] := ASignal[i];

  case ASpec.Kind of
    vkClean:
      ;   { 何もしない }

    vkAwgn:
      for i := 0 to ALen - 1 do
        Result[i] := Result[i] + noiseRms * rnd.NextGauss;

    vkExtremeQsb:
      { 振幅を周期的に沈める。Depth=0.95 なら谷で 5% まで落ちる。 }
      for i := 0 to ALen - 1 do
      begin
        t := i / ASampleRate;
        env := 1.0 - ASpec.Depth * 0.5 * (1.0 - Cos(2 * Pi * ASpec.RateHz * t));
        Result[i] := Result[i] * env + noiseRms * rnd.NextGauss;
      end;

    vkSelectiveFading:
      { 周波数によって沈み方が違う。2 つの経路が違う遅延で届き、
        干渉して周波数軸に櫛ができる状況を、遅延和で近似する。 }
      begin
        n := Max(1, Round(ASampleRate * 0.002));   { 2 ms の遅延 }
        for i := ALen - 1 downto 0 do
        begin
          t := i / ASampleRate;
          env := ASpec.Depth * 0.5 * (1.0 - Cos(2 * Pi * ASpec.RateHz * t));
          if i - n >= 0 then
            Result[i] := ASignal[i] - env * ASignal[i - n]
          else
            Result[i] := ASignal[i];
        end;
        for i := 0 to ALen - 1 do
          Result[i] := Result[i] + noiseRms * rnd.NextGauss;
      end;

    vkAdjacentQrm:
      { 隣の周波数で誰かが送信している。単なる純音ではなく、
        こちらもモールス的に断続させる (連続音だと復調器が
        簡単に無視できてしまい、混信として甘くなる)。 }
      begin
        ph := 0;
        { 搬送波からの相対で置く。CarrierHz が 0 のままだと絶対周波数に
          なってしまうので、そのときは分かるように 0 Hz ではなく
          信号帯の中央あたり (1000 Hz) を仮に使う。 }
        if ASpec.CarrierHz > 0 then
          dPh := 2 * Pi * (ASpec.CarrierHz + ASpec.OffsetHz) / ASampleRate
        else
          dPh := 2 * Pi * (1000 + ASpec.OffsetHz) / ASampleRate;
        for i := 0 to ALen - 1 do
        begin
          t := i / ASampleRate;
          { 3 Hz で断続 }
          if Frac(t * 3.0) < 0.6 then
            Result[i] := Result[i] + sigRms * ASpec.Level * Sqrt(2.0) * Sin(ph);
          ph := ph + dPh;
          if ph > 2 * Pi then ph := ph - 2 * Pi;
          Result[i] := Result[i] + noiseRms * rnd.NextGauss;
        end;
      end;

    vkImpulseNoise:
      begin
        for i := 0 to ALen - 1 do
          Result[i] := Result[i] + noiseRms * rnd.NextGauss;
        { 平均間隔から指数分布で次の衝撃までを決める。 }
        if ASpec.PerSecond > 0 then
        begin
          meanGap := ASampleRate / ASpec.PerSecond;
          nextImpulse := meanGap * (0.5 + rnd.NextFloat);
          i := 0;
          while i < ALen do
          begin
            if i >= Trunc(nextImpulse) then
            begin
              { 数標本の短い衝撃。 }
              for j := 0 to 2 do
                if i + j < ALen then
                  Result[i + j] := Result[i + j] +
                    sigRms * ASpec.Level * (1.0 - 2.0 * rnd.NextFloat);
              nextImpulse := nextImpulse - meanGap * Ln(Max(1E-12, rnd.NextFloat));
            end;
            Inc(i);
          end;
        end;
      end;

    vkFrequencyDrift:
      begin
        { 受信中に搬送波がずれていく。

          実信号にそのまま cos(位相) を掛けてはならない。それは周波数を
          動かすのではなく **振幅変調** で、和成分と差成分の両方が出て
          しまう (最初そう書いていて、測ったら「ドリフト耐性」ではなく
          別のものを測っていた)。

          正しくは解析信号 (負の周波数を落とした複素信号) にしてから
          複素回転を掛け、実部を取る。これで片側だけがずれる。 }
        ShiftFrequencyLinear(Result, ALen, ASampleRate, 0, ASpec.OffsetHz);
        for i := 0 to ALen - 1 do
          Result[i] := Result[i] + noiseRms * rnd.NextGauss;
      end;

    vkClipping:
      begin
        lim := sigRms * ASpec.Level;
        for i := 0 to ALen - 1 do
        begin
          Result[i] := Result[i] + noiseRms * rnd.NextGauss;
          if Result[i] > lim then Result[i] := lim
          else if Result[i] < -lim then Result[i] := -lim;
        end;
      end;
  end;
end;

procedure ShiftFrequencyLinear(var AWave: TDoubleArray; ALen, ASampleRate: Integer;
  AFromHz, AToHz: Double);
var
  n, i: Integer;
  buf: TComplexArray;
  t, f, ph, dur: Double;
begin
  { 解析信号にしてから複素回転を掛ける。回転の角周波数を時間とともに
    AFromHz から AToHz へ直線的に動かす (位相はその積分なので t の
    二次式になる)。

    FFT は 2 の冪乗が要るので後ろを 0 で埋める。埋めた分は捨てる。 }
  if ALen <= 1 then Exit;
  n := 1;
  while n < ALen do n := n * 2;
  SetLength(buf, n);
  for i := 0 to ALen - 1 do
    buf[i] := CplxMake(AWave[i], 0);
  for i := ALen to n - 1 do
    buf[i] := CplxMake(0, 0);

  ComplexFFT(buf);
  { 解析信号: 負の周波数を 0 にし、正の周波数を 2 倍する。
    直流とナイキストはそのまま。 }
  for i := 1 to n div 2 - 1 do
    buf[i] := CplxMake(buf[i].Re * 2, buf[i].Im * 2);
  for i := n div 2 + 1 to n - 1 do
    buf[i] := CplxMake(0, 0);
  InverseComplexFFT(buf);

  dur := ALen / ASampleRate;
  if dur <= 0 then Exit;
  for i := 0 to ALen - 1 do
  begin
    t := i / ASampleRate;
    { f(t) = AFromHz + (AToHz - AFromHz) * t / dur
      位相 = 2*Pi * (AFromHz*t + (AToHz-AFromHz)*t^2/(2*dur)) }
    f := AFromHz * t + (AToHz - AFromHz) * t * t / (2 * dur);
    ph := 2 * Pi * f;
    { (a+jb) * (cos+jsin) の実部 }
    AWave[i] := buf[i].Re * Cos(ph) - buf[i].Im * Sin(ph);
  end;
end;

{$push}
{$Q-}{$R-}   { FNV-1a の乗算は 2^64 で折り返すのが仕様 (NextU64 と同じ理由) }

function WaveChecksum(const AWave: array of Double; ALen: Integer): QWord;
var
  i: Integer;
  v: Int64;
begin
  { FNV-1a 風。値は 1e-9 の桁で丸めてから畳み込む。 }
  { FNV-1a の offset basis。上下に分けて書く理由は Seed と同じ。 }
  Result := (QWord($CBF29CE4) shl 32) or QWord($84222325);
  for i := 0 to ALen - 1 do
  begin
    v := Round(AWave[i] * 1E9);
    Result := Result xor QWord(v);
    Result := Result * QWord($100000001B3);   { FNV-1a prime }
  end;
end;

{$pop}

end.
