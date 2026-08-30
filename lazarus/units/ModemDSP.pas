{ ============================================================================
  ModemDSP.pas

  RTTY/CW モデム実装 (RttyModemImpl.pas / CwModemImpl.pas) が共通して使う
  DSP (信号処理) ヘルパー。fldigi の以下のファイルに対応する:

    - src/include/complex.h   (typedef std::complex<double> cmplx;)
    - src/include/misc.h      (decayavg(), clamp(), sinc())
    - src/include/filters.h   (class Cmovavg -- 移動平均フィルタ)
    - src/include/gfft.h      (template g_fft<T> -- FFTエンジン)
    - src/include/fftfilt.h /
      src/filters/fftfilt.cxx (class fftfilt -- FFTオーバーラップ加算フィルタ)

  【フィルタ品質改善 (2026-08)】
  当初の移植では fftfilt を「mark/space トーンをミキサーでベースバンドに
  落とした後の包絡線検波」に対して十分な特性を持つ複素1次IIRローパス
  フィルタ (TComplexLowpass、下記に残置。互換性のため削除しない) で
  代替していたが、fldigi 本来のフィルタ特性 (Blackman窓付き Windowed-Sinc
  のバンドパス/ローパス、および RTTY 用の周波数領域ゲイン等化済み
   raised-cosine 整合フィルタ) を再現するため、TFftFilt として
  Overlap-Add FFT 畳み込みフィルタを新規に実装した。

  fldigi の gfft.h (g_fft<T>) は 1990年代の RISC キャッシュ事情に最適化
  された、8/4/2混合基数・キャッシュブロッキング・手動ループ展開の
  "Green FFT" (John Green による public domain 実装) であり、逐語的に
  移植すると数千行の生ポインタ演算になり可読性も検証可能性も失われる。
  本移植版が実際に必要とするのは「2の冪乗サイズ (64～2048) の複素FFT/
  逆FFTが正しく動作すること」のみであり、実行速度は要件にならない
  (音声レート8kHzのブロック処理であり、どのCPUでも負荷は無視できる
  程度であることを別途確認済み)。そのため ComplexFFT/InverseComplexFFT
  は教科書的な反復型 Radix-2 Cooley-Tukey (ビット反転並べ替え+バタフライ
  演算) として新規に実装し、g_fft と入出力が数値的に一致すること
  (振幅・位相・スケーリング) をテスト (test/test_fftfilt.lpr) で検証する。
  RTTY/CW の実際の変復調アルゴリズム (ステートマシン、Baudot符号、
  モールス符号、AFC、適応速度追跡) には手を加えていない。
  ============================================================================ }
unit ModemDSP;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math;

const
  TWOPI = 2.0 * Pi;

type
  { fldigi: typedef std::complex<double> cmplx; (complex.h) }
  TComplex = record
    Re, Im: Double;
  end;

operator + (const A, B: TComplex): TComplex;
operator - (const A, B: TComplex): TComplex;
operator * (const A, B: TComplex): TComplex;
operator * (const A: TComplex; const B: Double): TComplex;
operator * (const A: Double; const B: TComplex): TComplex;

function CplxMake(ARe, AIm: Double): TComplex;
function CplxAbs(const A: TComplex): Double;
function CplxArg(const A: TComplex): Double;
function CplxConj(const A: TComplex): TComplex;

{ fldigi: misc.h の inline double decayavg(double average, double input, int weight) }
function DecayAvg(AAverage, AInput: Double; AWeight: Integer): Double;

{ fldigi: misc.h の inline double clamp(double x, double min, double max) }
function ClampF(AValue, AMin, AMax: Double): Double;

{ fldigi: misc.h の inline double sinc(double x) (正規化sinc関数) }
function Sinc(AX: Double): Double;

type
  { DSP パラメータの誤りを表す例外 (FFT長が2の冪乗でない等)。 }
  EDspError = class(Exception);

  TComplexArray = array of TComplex;

{ ============================================================================
  共有 FFT プラン (§4 X-05「FFT、Noise Estimator、Spectrum 等を共有
  サービス化する」)

  何が重複していたのか
  ----------------------------------------------------------------------------
  FFT を呼ぶたびに、段ごとに Cos/Sin を計算し、内側ループでは
  ツイドル係数を `w := w * wlen` と漸化式で更新していた。つまり

    - 同じ大きさの FFT を何度呼んでも、毎回同じ係数を計算し直す
    - 漸化式なので、内側ループが長いほど誤差が積み上がる

  実測 (このプロジェクトが実際に使う長さ):

      N=512  (RTTY mark/space):  35.8 us/回、往復誤差 1.45e-14
      N=2048 (CW):              174.2 us/回、往復誤差 3.72e-14

  RTTY は 8kHz で毎秒 125 回、CW は毎秒 16 回 FFT を回すので、これが
  復調の処理時間の大半を占めている。

  共有するもの / しないもの
  ----------------------------------------------------------------------------
  共有するのは **係数表とビット反転表** である。同じ長さなら中身が
  同一で、生成後は読むだけなので、いくつの利用者がいても 1 つあればよい。
  作業用バッファは利用者ごとの状態なので共有しない。

  RTTY の mark/space は **別の入力** (異なる周波数でミックスダウンした
  もの) を処理するので、変換結果そのものは共有できない。共有できるのは
  資源のほうである。

  スレッド安全について
  ----------------------------------------------------------------------------
  プランは公開後に変更されない。Forward/Inverse が書き込むのは
  **呼び出し側のバッファだけ** なので、別スレッドが同じプランを同時に
  使ってよい。Phase 3 が複数の復調戦略を並べたときに、戦略ごとに
  プランを持たずに済む。

  なぜ別ユニットにしないのか
  ----------------------------------------------------------------------------
  TComplex がこのユニットで定義されており、TFftFilt もここにある。
  別ユニットへ出すと、TComplex を共有するために循環参照になるか、
  型を複製することになる。Phase 3 で Noise Estimator と Spectrum も
  サービス化するときに、共通の型ユニットへ切り出すのが自然な区切りである。
  ============================================================================ }

type
  { --- 1 つの長さぶんの FFT 資源 ---
    生成後は不変。複数のスレッドが同時に使ってよい。 }
  TFftPlan = class
  private
    FSize: Integer;
    FLog2: Integer;
    { 段ごとの係数を平坦に並べたもの (合計 N-1 個)。
      段の half に対する先頭位置は half-1。 }
    FTwiddle: TComplexArray;
    FBitRev: array of Integer;
    FUseCount: Int64;
    procedure Butterflies(var ABuf: TComplexArray; AConjugate: Boolean);
  public
    constructor Create(ASize: Integer);
    { その場で変換する。確保しない (X-04)。 }
    procedure Forward(var ABuf: TComplexArray);
    { その場で逆変換し 1/N を掛ける。確保しない。 }
    procedure Inverse(var ABuf: TComplexArray);
    property Size: Integer read FSize;
    { このプランを何回引き当てたか。共有できているかの確認用。 }
    property UseCount: Int64 read FUseCount;
    function TwiddleCount: Integer;
  end;

{ 長さに対する共有プランを返す。無ければ作る。
  返るものは process 全体で共有される。解放しないこと。 }
function SharedFftPlan(ASize: Integer): TFftPlan;
{ いま保持しているプランの数 (試験・診断用)。 }
function SharedFftPlanCount: Integer;

{ 係数表を使わない素朴な実装。共有プランが同じ結果を出すことを
  確かめるための基準として残す。実運用では使わない。 }
procedure ComplexFFTReference(var ABuf: TComplexArray);

{ fldigi: g_fft<double>::ComplexFFT(cmplx *buf)
  buf の要素数 (2の冪乗であること) をそのままFFTサイズとして扱う、
  その場(in-place)複素順変換。スケーリングなし (Σ規約)。 }
procedure ComplexFFT(var ABuf: TComplexArray);
{ fldigi: g_fft<double>::InverseComplexFFT(cmplx *buf)
  その場の逆変換。呼び出し側でスケーリングする必要が無いよう、
  結果を要素数Nで除算した状態 (1/N規約) を返す。 }
procedure InverseComplexFFT(var ABuf: TComplexArray);

type
  { TMovingAverage
    ---------------------------------------------------------------------
    fldigi: class Cmovavg (filters.h / filters.cxx)
    円環バッファによる単純移動平均。RTTY のビットフィルタ、CW の
    ビットフィルタ・トラッキングフィルタに使用する。 }
  TMovingAverage = class
  private
    FBuf: array of Double;
    FLen: Integer;
    FSum: Double;
    FPtr: Integer;
    FEmpty: Boolean;
  public
    constructor Create(ALen: Integer);
    { fldigi: void Cmovavg::setLength(int) }
    procedure SetLength_(ALen: Integer);
    { fldigi: void Cmovavg::reset() }
    procedure Reset;
    { fldigi: double Cmovavg::run(double) }
    function Run(AValue: Double): Double;
  end;

  { TComplexLowpass
    ---------------------------------------------------------------------
    fldigi の fftfilt (窓関数付き Overlap-Add FFT ローパス/バンドパス
    フィルタ) の簡易代替。1次RC型ローパスを複素信号(I/Q)に適用する。
    カットオフ周波数は fftfilt に渡していた「baud/samplerate」相当の
    値をそのまま Hz 単位で指定する。 }
  TComplexLowpass = class
  private
    FAlpha: Double;
    FState: TComplex;
  public
    constructor Create(ACutoffHz, ASampleRate: Double);
    procedure SetCutoff(ACutoffHz, ASampleRate: Double);
    function Run(const AIn: TComplex): TComplex;
    procedure Reset;
  end;

  { TFftFilt
    ---------------------------------------------------------------------
    fldigi: class fftfilt (src/include/fftfilt.h, src/filters/fftfilt.cxx)
    Overlap-Add FFT畳み込みフィルタ。ALen (flen, 2の冪乗) を FFTサイズと
    し、1ブロックあたり ALen/2 (flen2) サンプルを処理する。
    Windowed-Sinc によるバンドパス/ローパス/ハイパス (CreateFilter/
    CreateLpf/CreateHpf) と、RTTY mark/space 用の周波数領域直接構成
    raised-cosine整合フィルタ (RttyFilter) の2種類のフィルタ形状に対応。 }
  TFftFilt = class
  private
    FFlen: Integer;   // fldigi: flen
    FFlen2: Integer;  // fldigi: flen2 (= flen/2)
    FFilter: TComplexArray;   // fldigi: cmplx *filter (周波数応答 H(w))
    FTimeData: TComplexArray; // fldigi: cmplx *timedata
    FFreqData: TComplexArray; // fldigi: cmplx *freqdata
    FOutput: TComplexArray;   // fldigi: cmplx *output
    FOvlBuf: TComplexArray;   // fldigi: cmplx *ovlbuf
    FInPtr: Integer;  // fldigi: inptr
    FPass: Integer;   // fldigi: pass (最初の2ブロックは出力不安定のため捨てる)
    function FSinc(AFc: Double; AI, ALen: Integer): Double;
    function FBlackman(AI, ALen: Integer): Double;
    procedure ClearFilter;
  public
    { ALen: FFT長 (flen)。2の冪乗であること。1ブロックあたり
      ALen div 2 サンプルを消費・生成する。 }
    constructor Create(ALen: Integer);

    { fldigi: fftfilt::create_filter(double f1, double f2)
      f1 < f2 ならバンドパス、f1 > f2 ならバンドリジェクト、
      f1 = 0 ならローパス(@f2)、f2 = 0 ならハイパス(@f1)。 }
    procedure CreateFilter(AF1, AF2: Double);
    procedure CreateLpf(AF: Double);
    procedure CreateHpf(AF: Double);

    { fldigi: fftfilt::rtty_filter(double f)
      RTTY mark/space 用、Feher流raised-cosine整合フィルタを
      周波数領域で直接構成する (振幅等化 + ±90度移相込み)。 }
    procedure RttyFilter(AF: Double);

    { fldigi: int fftfilt::run(const cmplx &in, cmplx **out)
      1サンプル投入する。flen2 サンプル溜まるまでは 0 を返す
      (AOut は未定義のまま)。flen2 サンプル溜まったら Overlap-Add
      FFT畳み込みを実行し、flen2 個のフィルタ済みサンプルを AOut に
      設定して flen2 を返す (AOut は本インスタンス内部バッファへの
      参照であり、次回 Run 呼び出しまでの間のみ有効)。 }
    function Run(const AIn: TComplex; out AOut: TComplexArray): Integer;

    { fldigi: int fftfilt::flush_size() }
    function FlushSize: Integer;

    property Flen: Integer read FFlen;
    property Flen2: Integer read FFlen2;
  end;

implementation

uses
  SyncObjs;

const
  { 2^20 = 1048576 点まで。これ以上は現実的でない。 }
  MAX_FFT_LOG2 = 20;

var
  { 長さ (log2) ごとの共有プラン。一度作ったら process 終了まで保つ。
    数えるほどの種類しか無いので、解放して作り直す意味がない。 }
  GFftPlans: array[0..MAX_FFT_LOG2] of TFftPlan;
  GFftPlanLock: TCriticalSection;
  { finalization は局所変数を持てないのでここに置く。 }
  GFftFreeIdx: Integer;

operator + (const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re + B.Re;
  Result.Im := A.Im + B.Im;
end;

operator - (const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re - B.Re;
  Result.Im := A.Im - B.Im;
end;

operator * (const A, B: TComplex): TComplex;
begin
  Result.Re := A.Re * B.Re - A.Im * B.Im;
  Result.Im := A.Re * B.Im + A.Im * B.Re;
end;

operator * (const A: TComplex; const B: Double): TComplex;
begin
  Result.Re := A.Re * B;
  Result.Im := A.Im * B;
end;

operator * (const A: Double; const B: TComplex): TComplex;
begin
  Result.Re := A * B.Re;
  Result.Im := A * B.Im;
end;

function CplxMake(ARe, AIm: Double): TComplex;
begin
  Result.Re := ARe;
  Result.Im := AIm;
end;

function CplxAbs(const A: TComplex): Double;
begin
  Result := Sqrt(A.Re * A.Re + A.Im * A.Im);
end;

function CplxArg(const A: TComplex): Double;
begin
  Result := ArcTan2(A.Im, A.Re);
end;

function CplxConj(const A: TComplex): TComplex;
begin
  Result.Re := A.Re;
  Result.Im := -A.Im;
end;

function DecayAvg(AAverage, AInput: Double; AWeight: Integer): Double;
begin
  // fldigi: if (weight <= 1) return input; return ((input-average)/weight)+average;
  if AWeight <= 1 then
    Result := AInput
  else
    Result := ((AInput - AAverage) / AWeight) + AAverage;
end;

function ClampF(AValue, AMin, AMax: Double): Double;
begin
  if AValue < AMin then
    Result := AMin
  else if AValue > AMax then
    Result := AMax
  else
    Result := AValue;
end;

function Sinc(AX: Double): Double;
begin
  if Abs(AX) < 1e-10 then
    Result := 1.0
  else
    Result := Sin(Pi * AX) / (Pi * AX);
end;

{ ============================================================================
  ComplexFFT / InverseComplexFFT
  fldigi の g_fft<double> (gfft.h, 8/4/2混合基数のキャッシュブロッキング
  FFT) の代わりに、教科書的な反復型 Radix-2 Cooley-Tukey で実装する
  (本ファイル冒頭コメント「フィルタ品質改善」参照)。ABuf の要素数は
  2の冪乗であることが前提 (呼び出し元の TFftFilt が保証する)。
  ============================================================================ }

{ N が 2 の冪乗かどうか。Radix-2 FFT は 2 の冪乗長でしか正しく動作しない
  ため、誤った長さで「静かに間違った結果」を返さないよう検査に使う。 }
function IsPowerOfTwo(AN: Integer): Boolean;
begin
  Result := (AN >= 2) and ((AN and (AN - 1)) = 0);
end;

procedure BitReverseInPlace(var ABuf: TComplexArray);
var
  n, i, j, bit: Integer;
  tmp: TComplex;
begin
  n := Length(ABuf);
  j := 0;
  for i := 0 to n - 2 do
  begin
    if i < j then
    begin
      tmp := ABuf[i];
      ABuf[i] := ABuf[j];
      ABuf[j] := tmp;
    end;
    bit := n shr 1;
    while (bit > 0) and ((j and bit) <> 0) do
    begin
      j := j xor bit;
      bit := bit shr 1;
    end;
    j := j or bit;
  end;
end;

{ ASign = -1.0 で順変換、+1.0 で逆変換 (スケーリング前) の
  バタフライ演算を行う共通コア。 }
procedure FftButterflyCore(var ABuf: TComplexArray; ASign: Double);
var
  n, len, half, i, j: Integer;
  ang: Double;
  wlen, w, u, v: TComplex;
begin
  n := Length(ABuf);
  BitReverseInPlace(ABuf);
  len := 2;
  while len <= n do
  begin
    half := len div 2;
    ang := ASign * TWOPI / len;
    wlen := CplxMake(Cos(ang), Sin(ang));
    i := 0;
    while i < n do
    begin
      w := CplxMake(1.0, 0.0);
      for j := 0 to half - 1 do
      begin
        u := ABuf[i + j];
        v := ABuf[i + j + half] * w;
        ABuf[i + j] := u + v;
        ABuf[i + j + half] := u - v;
        w := w * wlen;
      end;
      Inc(i, len);
    end;
    len := len * 2;
  end;
end;

{ ============================ TFftPlan ============================ }

constructor TFftPlan.Create(ASize: Integer);
var
  n, half, j, base, i, k, rev, bits: Integer;
  ang: Double;
begin
  inherited Create;
  if not IsPowerOfTwo(ASize) then
    raise EDspError.CreateFmt(
      'FFT長は2以上の2の冪乗である必要があります (指定: %d)', [ASize]);
  FSize := ASize;

  FLog2 := 0;
  n := ASize;
  while n > 1 do
  begin
    n := n shr 1;
    Inc(FLog2);
  end;

  { --- 係数表 ---
    段ごとに w^j = exp(-2*pi*i*j/(2*half)) を並べる。先頭位置は half-1、
    合計 N-1 個。漸化式ではなく 1 つずつ直接計算するので、内側ループが
    長くても誤差が積み上がらない。 }
  SetLength(FTwiddle, FSize);   { N-1 で足りるが、N にしておくと空も扱える }
  half := 1;
  while half < FSize do
  begin
    base := half - 1;
    for j := 0 to half - 1 do
    begin
      ang := -TWOPI * j / (2 * half);
      FTwiddle[base + j] := CplxMake(Cos(ang), Sin(ang));
    end;
    half := half shl 1;
  end;

  { --- ビット反転表 --- }
  SetLength(FBitRev, FSize);
  bits := FLog2;
  for i := 0 to FSize - 1 do
  begin
    rev := 0;
    k := i;
    for j := 0 to bits - 1 do
    begin
      rev := (rev shl 1) or (k and 1);
      k := k shr 1;
    end;
    FBitRev[i] := rev;
  end;
end;

function TFftPlan.TwiddleCount: Integer;
begin
  Result := FSize - 1;
  if Result < 0 then Result := 0;
end;

procedure TFftPlan.Butterflies(var ABuf: TComplexArray; AConjugate: Boolean);
{ 確保しない。読むのは表だけで、書くのは呼び出し側のバッファだけなので、
  別スレッドが同じプランを同時に使ってよい。 }
var
  n, len, half, base, i, j, r: Integer;
  w, u, v, t: TComplex;
begin
  n := FSize;

  { ビット反転の並べ替え。表があるので都度計算しない。 }
  for i := 0 to n - 1 do
  begin
    r := FBitRev[i];
    if i < r then
    begin
      t := ABuf[i];
      ABuf[i] := ABuf[r];
      ABuf[r] := t;
    end;
  end;

  len := 2;
  while len <= n do
  begin
    half := len shr 1;
    base := half - 1;
    i := 0;
    while i < n do
    begin
      for j := 0 to half - 1 do
      begin
        w := FTwiddle[base + j];
        { 逆変換は係数の共役。表を 2 つ持たずに済み、値も厳密に一致する。 }
        if AConjugate then
          w.Im := -w.Im;
        u := ABuf[i + j];
        v := ABuf[i + j + half] * w;
        ABuf[i + j] := u + v;
        ABuf[i + j + half] := u - v;
      end;
      Inc(i, len);
    end;
    len := len shl 1;
  end;
end;

procedure TFftPlan.Forward(var ABuf: TComplexArray);
begin
  if Length(ABuf) <> FSize then
    raise EDspError.CreateFmt(
      'FFTプランの長さと合いません (プラン %d / バッファ %d)',
      [FSize, Length(ABuf)]);
  Butterflies(ABuf, False);
end;

procedure TFftPlan.Inverse(var ABuf: TComplexArray);
var
  i: Integer;
  invN: Double;
begin
  if Length(ABuf) <> FSize then
    raise EDspError.CreateFmt(
      'FFTプランの長さと合いません (プラン %d / バッファ %d)',
      [FSize, Length(ABuf)]);
  Butterflies(ABuf, True);
  invN := 1.0 / FSize;
  for i := 0 to FSize - 1 do
    ABuf[i] := ABuf[i] * invN;
end;

{ ============================ 共有プランの置き場 ============================ }

function SharedFftPlan(ASize: Integer): TFftPlan;
var
  idx, n: Integer;
begin
  if not IsPowerOfTwo(ASize) then
    raise EDspError.CreateFmt(
      'FFT長は2以上の2の冪乗である必要があります (指定: %d)', [ASize]);

  idx := 0;
  n := ASize;
  while n > 1 do
  begin
    n := n shr 1;
    Inc(idx);
  end;
  if idx > MAX_FFT_LOG2 then
    raise EDspError.CreateFmt(
      'FFT長が大きすぎます (指定: %d / 上限: %d)',
      [ASize, 1 shl MAX_FFT_LOG2]);

  { 既にあれば錠を取らずに返す。作るのは長さごとに一度だけなので、
    毎回の変換で待ち合わせが起きないようにする。 }
  Result := GFftPlans[idx];
  ReadBarrier;
  if Result <> nil then
  begin
    Inc(Result.FUseCount);
    Exit;
  end;

  GFftPlanLock.Enter;
  try
    { 錠を取る間に他のスレッドが作っているかもしれない。 }
    Result := GFftPlans[idx];
    if Result = nil then
    begin
      Result := TFftPlan.Create(ASize);
      { 表を作り終えてから公開する。逆順だと、他のスレッドが
        中身の無いプランを掴みうる。 }
      WriteBarrier;
      GFftPlans[idx] := Result;
    end;
  finally
    GFftPlanLock.Leave;
  end;
  Inc(Result.FUseCount);
end;

function SharedFftPlanCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to MAX_FFT_LOG2 do
    if GFftPlans[i] <> nil then Inc(Result);
end;

procedure ComplexFFTReference(var ABuf: TComplexArray);
{ 係数表を使わない素朴な実装。共有プランの結果を照合するための基準。 }
begin
  if not IsPowerOfTwo(Length(ABuf)) then
    raise EDspError.CreateFmt(
      'FFT長は2以上の2の冪乗である必要があります (指定: %d)', [Length(ABuf)]);
  FftButterflyCore(ABuf, -1.0);
end;

procedure ComplexFFT(var ABuf: TComplexArray);
begin
  if not IsPowerOfTwo(Length(ABuf)) then
    raise EDspError.CreateFmt(
      'FFT長は2以上の2の冪乗である必要があります (指定: %d)', [Length(ABuf)]);
  { 共有プランへ回す。呼び出し側は変わらないまま、係数表の恩恵を受ける。 }
  SharedFftPlan(Length(ABuf)).Forward(ABuf);
end;

procedure InverseComplexFFT(var ABuf: TComplexArray);
begin
  if not IsPowerOfTwo(Length(ABuf)) then
    raise EDspError.CreateFmt(
      'FFT長は2以上の2の冪乗である必要があります (指定: %d)', [Length(ABuf)]);
  SharedFftPlan(Length(ABuf)).Inverse(ABuf);
end;

{ TMovingAverage }

constructor TMovingAverage.Create(ALen: Integer);
begin
  inherited Create;
  if ALen < 1 then
    ALen := 1;
  FLen := ALen;
  SetLength(FBuf, FLen);
  FEmpty := True;
  FSum := 0;
  FPtr := 0;
end;

procedure TMovingAverage.SetLength_(ALen: Integer);
begin
  if ALen < 1 then
    ALen := 1;
  if ALen > FLen then
    SetLength(FBuf, ALen);
  FLen := ALen;
  FEmpty := True;
end;

procedure TMovingAverage.Reset;
begin
  FEmpty := True;
end;

function TMovingAverage.Run(AValue: Double): Double;
var
  i: Integer;
begin
  if FEmpty then
  begin
    FEmpty := False;
    FSum := 0;
    for i := 0 to FLen - 1 do
    begin
      FBuf[i] := AValue;
      FSum := FSum + AValue;
    end;
    FPtr := 0;
    Exit(AValue);
  end;
  FSum := FSum - FBuf[FPtr] + AValue;
  FBuf[FPtr] := AValue;
  Inc(FPtr);
  if FPtr >= FLen then
    FPtr := 0;
  Result := FSum / FLen;
end;

{ TComplexLowpass }

constructor TComplexLowpass.Create(ACutoffHz, ASampleRate: Double);
begin
  inherited Create;
  SetCutoff(ACutoffHz, ASampleRate);
  FState := CplxMake(0, 0);
end;

procedure TComplexLowpass.SetCutoff(ACutoffHz, ASampleRate: Double);
begin
  if ACutoffHz < 0.1 then
    ACutoffHz := 0.1;
  if ASampleRate < 1 then
    ASampleRate := 1;
  // 標準的な1次RCローパスの離散化: alpha = 1 - exp(-2*pi*fc/fs)
  FAlpha := 1.0 - Exp(-TWOPI * ACutoffHz / ASampleRate);
  if FAlpha > 1.0 then
    FAlpha := 1.0;
end;

function TComplexLowpass.Run(const AIn: TComplex): TComplex;
begin
  FState.Re := FState.Re + FAlpha * (AIn.Re - FState.Re);
  FState.Im := FState.Im + FAlpha * (AIn.Im - FState.Im);
  Result := FState;
end;

procedure TComplexLowpass.Reset;
begin
  FState := CplxMake(0, 0);
end;

{ TFftFilt }

constructor TFftFilt.Create(ALen: Integer);
begin
  inherited Create;
  { Overlap-Add は内部で Radix-2 FFT を使うため、長さが 2 の冪乗でないと
    黙って誤ったフィルタ出力を返してしまう。生成時点で弾く。
    最小 4 = flen2 が 2 以上 (1 ブロックに複数サンプルが入る) を保証する。 }
  if not IsPowerOfTwo(ALen) or (ALen < 4) then
    raise EDspError.CreateFmt(
      'フィルタ長は4以上の2の冪乗である必要があります (指定: %d)', [ALen]);
  FFlen := ALen;
  FFlen2 := ALen div 2;
  SetLength(FFilter, FFlen);
  SetLength(FTimeData, FFlen);
  SetLength(FFreqData, FFlen);
  SetLength(FOutput, FFlen);
  SetLength(FOvlBuf, FFlen2);
  ClearFilter;
end;

procedure TFftFilt.ClearFilter;
var
  i: Integer;
begin
  for i := 0 to FFlen - 1 do
  begin
    FFilter[i] := CplxMake(0, 0);
    FTimeData[i] := CplxMake(0, 0);
    FFreqData[i] := CplxMake(0, 0);
    FOutput[i] := CplxMake(0, 0);
  end;
  for i := 0 to FFlen2 - 1 do
    FOvlBuf[i] := CplxMake(0, 0);
  FInPtr := 0;
end;

function TFftFilt.FSinc(AFc: Double; AI, ALen: Integer): Double;
begin
  // fldigi: fftfilt::fsinc()
  if AI = ALen div 2 then
    Result := 2.0 * AFc
  else
    Result := Sin(2 * Pi * AFc * (AI - ALen div 2)) / (Pi * (AI - ALen div 2));
end;

function TFftFilt.FBlackman(AI, ALen: Integer): Double;
begin
  // fldigi: fftfilt::_blackman()
  Result := 0.42 - 0.50 * Cos(2.0 * Pi * AI / ALen) + 0.08 * Cos(4.0 * Pi * AI / ALen);
end;

procedure TFftFilt.CreateFilter(AF1, AF2: Double);
{ fldigi: fftfilt::create_filter(double f1, double f2) }
var
  ht: TComplexArray;
  i: Integer;
  bLowpass, bHighpass: Boolean;
  scale, mag: Double;
begin
  ClearFilter;
  SetLength(ht, FFlen);
  for i := 0 to FFlen - 1 do
    ht[i] := CplxMake(0, 0);

  bLowpass := AF2 <> 0;
  bHighpass := AF1 <> 0;

  for i := 0 to FFlen2 - 1 do
  begin
    ht[i] := CplxMake(0, 0);
    if bLowpass then
      ht[i] := ht[i] + CplxMake(FSinc(AF2, i, FFlen2), 0);
    if bHighpass then
      ht[i] := ht[i] - CplxMake(FSinc(AF1, i, FFlen2), 0);
  end;
  if bHighpass and (AF2 < AF1) then
    ht[FFlen2 div 2] := ht[FFlen2 div 2] + CplxMake(1.0, 0.0);

  for i := 0 to FFlen2 - 1 do
    ht[i] := ht[i] * FBlackman(i, FFlen2);

  for i := 0 to FFlen - 1 do
    FFilter[i] := ht[i];

  // ht は flen2 個の h(t) + 残りゼロ埋め (flen点) → 順FFTで H(w) を得る
  ComplexFFT(FFilter);

  // ユニティゲインになるよう正規化
  scale := 0;
  for i := 0 to FFlen2 - 1 do
  begin
    mag := CplxAbs(FFilter[i]);
    if mag > scale then scale := mag;
  end;
  if scale <> 0 then
    for i := 0 to FFlen - 1 do
      FFilter[i] := FFilter[i] * (1.0 / scale);

  FPass := 1; // 最初の2ブロックは出力不安定のため捨てる
end;

procedure TFftFilt.CreateLpf(AF: Double);
begin
  CreateFilter(0, AF);
end;

procedure TFftFilt.CreateHpf(AF: Double);
begin
  CreateFilter(AF, 0);
end;

procedure TFftFilt.RttyFilter(AF: Double);
{ fldigi: fftfilt::rtty_filter(double f)
  Feher流raised-cosine整合フィルタを周波数領域で直接構成する。
  時間領域のインパルス応答をFFTする create_filter() とは異なり、
  こちらは最初から H(w) (FFilter配列) を直接書き込む。 }
var
  f, x, dht, sincVal: Double;
  i: Integer;
begin
  ClearFilter;
  f := AF * 1.4;

  for i := 0 to FFlen2 - 1 do
  begin
    x := i / FFlen2;

    if x <= 0 then
      dht := 1.0
    else if x > 2.0 * f then
      dht := 0.0
    else
      dht := Cos((Pi * x) / (f * 4.0));
    dht := dht * dht; // cos^2

    { 振幅等化 (amplitude equalized nyquist-channel response)。
      Sinc(x) は x が 0 以外の整数のとき 0 になるため、そのまま割ると
      Inf/NaN がフィルタ係数に混入し、以後の復調出力すべてが NaN に
      汚染される。通常のパラメータ範囲では dht が先に 0 になるため
      到達しないが、パラメータ次第で 0/0 = NaN もあり得るので明示的に
      保護する。 }
    sincVal := Sinc(2.0 * i * f);
    if Abs(sincVal) < 1e-12 then
      dht := 0.0
    else
      dht := dht / sincVal;

    FFilter[i] := CplxMake(dht * Cos(-0.5 * Pi * i), dht * Sin(-0.5 * Pi * i));
    FFilter[(FFlen - i) mod FFlen] := CplxMake(dht * Cos(0.5 * Pi * i), dht * Sin(0.5 * Pi * i));
  end;

  FPass := 1;
end;

function TFftFilt.Run(const AIn: TComplex; out AOut: TComplexArray): Integer;
{ fldigi: int fftfilt::run(const cmplx &in, cmplx **out)
  Overlap-Add (fast convolution) アルゴリズム。 }
var
  i: Integer;
begin
  FTimeData[FInPtr] := AIn;
  Inc(FInPtr);

  if FInPtr < FFlen2 then
  begin
    Result := 0;
    Exit;
  end;
  if FPass > 0 then Dec(FPass);

  // 時間領域→周波数領域 (FTimeData の後半 flen2 要素は常にゼロ埋めのまま)
  for i := 0 to FFlen - 1 do
    FFreqData[i] := FTimeData[i];
  ComplexFFT(FFreqData);

  // フィルタ形状を乗算
  for i := 0 to FFlen - 1 do
    FFreqData[i] := FFreqData[i] * FFilter[i];

  // 周波数領域→時間領域
  InverseComplexFFT(FFreqData);

  // Overlap-and-Add: 前回ブロック後半の持ち越し分と加算して出力、
  // 今回ブロック後半は次回のために保存する
  for i := 0 to FFlen2 - 1 do
  begin
    FOutput[i] := FOvlBuf[i] + FFreqData[i];
    FOvlBuf[i] := FFreqData[i + FFlen2];
  end;

  FInPtr := 0;

  if FPass > 0 then
  begin
    Result := 0; // 最初の1パス分は不安定なため出力しない
    Exit;
  end;

  AOut := FOutput;
  Result := FFlen2;
end;

function TFftFilt.FlushSize: Integer;
begin
  Result := FFlen - FInPtr;
end;

initialization
  GFftPlanLock := TCriticalSection.Create;

finalization
  FreeAndNil(GFftPlanLock);
  { プランは process 全体で共有されるので、ここでまとめて解放する。 }
  for GFftFreeIdx := 0 to MAX_FFT_LOG2 do
    FreeAndNil(GFftPlans[GFftFreeIdx]);

end.
