{ ============================================================================
  SpectrumService.pas

  スペクトルを **一度だけ計算して皆で使う** ための共有サービス
  (Baseline v1.1 §4 X-05「FFT、Noise Estimator、Spectrum 等を共有サービス化
  する」のうち Spectrum の部分)。

  なぜ共有サービスにするのか
  ----------------------------------------------------------------------------
  スペクトルを欲しがるものは 1 つではない。

      Basic Waterfall              Phase 2  表示
      Noise Estimator              Phase 3  雑音床の推定
      Reception State Estimator    Phase 3  受信状態の判定
      自動信号発見 / Mode 推定      Phase 3  信号の在処と種類
      Algorithm Portfolio          Phase 3  複数戦略が同じ音を見る

  それぞれが自前で FFT を回すと、同じ計算を人数分繰り返すことになる。
  X-05 が「資源の重複を無くす」と言っているのはこのことである。

  Event Bus には載せない
  ----------------------------------------------------------------------------
  §5.1 と ADR-001 は、Audio / IQ / **Spectrum** / DSP Frame のような広帯域・
  高頻度データを Data Plane (Ring Buffer / bounded queue / 共有バッファ) で
  扱い、Event Bus には載せないと定めている (要求 ARC-001)。
  このユニットは EventBus を uses しない。共有バッファを直接読ませる。

  読み手ごとに要求が違う
  ----------------------------------------------------------------------------
      Waterfall        最新が見えればよい。取りこぼしても表示が飛ぶだけ。
      Noise Estimator  全枠が要る。取りこぼすと統計が偏る。

  そこで **輪 + 読み手ごとの位置** にした。読み手は自分の位置を持ち、
  追い越されたら **黙って飛ばさず「何枠飛ばしたか」を返す**。
  黙って飛ばすと、統計を取る側は自分が偏っていることに気づけない
  (AudioRing.TAudioHistory で同じ規律を敷いている)。

  諸元
  ----------------------------------------------------------------------------
  FFT 長の既定は 8192。8 kHz で 1 bin = 0.98 Hz になり、PSK31 の幅 (約 31 Hz)
  を見分けられる。fldigi の WF_FFTLEN と同じ値である。
  送り幅 (hop) の既定は FFT 長の 1/4 で、窓は 75% 重なる。重ねるのは、
  窓の端で弱まった信号を隣の窓が拾うためである。

  出力は **線形のパワー**。dB は表示のための表現であって、雑音床の推定は
  線形で行う。素の量を持ち、変換は使う側に任せる。

  正規化の約束 —— ここは読み手ごとに要る量が違う
  ----------------------------------------------------------------------------
  枠の値は **窓の利得 (coherent gain) で正規化した線形パワー** である。
  すなわち、bin の中心にある振幅 A の正弦波は、その bin に A^2/2
  (= 正弦波の平均電力) として現れる。窓を変えても値は変わらない。
  波形表示・信号発見・S メータのように「その信号がどれだけ強いか」を
  知りたい側は、これをそのまま読めばよい。

  ところが **雑音は違う**。雑音は 1 本の bin に集まらず全 bin に散るので、
  1 bin が拾う量は窓の等価雑音帯域幅 (ENBW) と FFT 長に比例してしまう。
  窓を Hann から Blackman に替えただけで雑音床が 0.6 dB 動く、というのでは
  Phase 3 の Noise Estimator は較正できない。
  そこで ENBW を持ち、PowerToDensity で **1 Hz あたりの電力密度** に直せる
  ようにした。密度にすれば窓にも FFT 長にも依らない量になる。

      信号の強さを知りたい  -> 枠の値をそのまま (A^2/2)
      雑音の床を知りたい    -> PowerToDensity を通す (/Hz)

  ENBW は窓の形だけで決まる量なので、**ここで一度求めて配る**。
  読み手それぞれが 1.5 や 1.7269 を書き写すと、いずれ食い違う (X-05)。

  実装の選択について
  ----------------------------------------------------------------------------
  入力は実数だが、複素 FFT をそのまま使っている。実数専用の FFT なら計算量は
  半分になるが、8192 点を毎秒 4 回でも 1 秒あたり数十万回の蝶演算にすぎない。
  **測って足りないと分かってから**専用実装を入れる (README §28 で学んだ順序)。
  共有プラン (ModemDSP.SharedFftPlan) を通すので、係数表は他の利用者と
  共有される。
  ============================================================================ }
unit SpectrumService;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemTypes, ModemDSP;

const
  { 既定の FFT 長。8 kHz で 0.98 Hz/bin。 }
  SPECTRUM_DEFAULT_FFT = 8192;
  { 保持する枠の数。読み手が少し遅れても取りこぼさない程度。
    表示の巻物は使う側が自前で持つので、ここは受け渡しの余裕だけでよい。 }
  SPECTRUM_DEFAULT_FRAMES = 64;

type
  ESpectrumError = class(Exception);

  { 窓関数。端で信号を絞ることで、隣の bin への漏れを抑える。 }
  TSpectrumWindow = (
    swRectangular,   // 絞らない。漏れが大きいが振幅は正確
    swHann,          // 既定。汎用
    swHamming,
    swBlackman       // 漏れが最も小さい。分解能は落ちる
  );

  { 読み出しの結果。
    srOk 以外はすべて「枠は返していない」。もう一度呼べば先へ進む。 }
  TSpectrumReadResult = (
    srOk,        // 枠を 1 つ取り出した
    srNoData,    // まだ新しい枠が無い (追いついている)
    srMissed,    // 追い越された。位置を最古の生存枠へ進めた
    srReset      // 流し直された。位置を新しい流れの先頭へ戻した
  );

  { 1 枠の素性。 }
  TSpectrumFrameInfo = record
    Sequence: Int64;      // 通し番号 (0 から)
    StartSample: Int64;   // 窓の先頭の通算サンプル位置
    MissedFrames: Int64;  // srMissed のとき、飛ばした枠数
    function Describe: string;
  end;

  { 読み手の位置。使う側が持つ。
    サービス側に登録しないので、読み手が増えても減っても
    サービスは何も知らなくてよい。

    Epoch は「どの流れを読んでいるか」。Reset のたびに進むので、
    流し直しをまたいだ読み手を見分けられる (下の srReset を参照)。 }
  TSpectrumReader = record
    NextSeq: Int64;
    Epoch: Int64;
  end;

  TSpectrumService = class
  private
    FFftSize: Integer;
    FBinCount: Integer;       // FFftSize div 2 + 1
    FHop: Integer;
    FSampleRate: Integer;
    FWindowKind: TSpectrumWindow;
    FWindow: array of Double;
    FWindowSum: Double;       // 窓の総和 (振幅の正規化に使う)
    FEnbwBins: Double;        // 窓の等価雑音帯域幅 [bin] (雑音の正規化に使う)

    { 入力の溜め。FFftSize 個たまったら 1 枠作り、hop だけ捨てる。 }
    FAccum: array of Double;
    FFill: Integer;

    { FFT の作業用。毎回確保しないよう持っておく (X-04)。 }
    FWork: TComplexArray;

    { 枠の輪。平坦に並べる。 }
    FFrames: array of Double;
    FFrameCapacity: Integer;
    { AudioHistory と同じ二段。予約は上書き判定に、確定は読める判定に使う。 }
    FReserved: Int64;
    FCommitted: Int64;
    FEpoch: Int64;            // Reset のたびに進む。流れの世代

    FTotalSamples: Int64;

    procedure BuildWindow;
    procedure EmitFrame;
  public
    constructor Create(AFftSize: Integer = SPECTRUM_DEFAULT_FFT;
      ASampleRate: Integer = 8000;
      AHop: Integer = 0;
      AWindowKind: TSpectrumWindow = swHann;
      AFrameCapacity: Integer = SPECTRUM_DEFAULT_FRAMES);

    { 音声を入れる。FFT 1 個ぶん溜まるたびに枠ができる。確保しない (X-04)。 }
    procedure Feed(const ABuf: array of Double; ALen: Integer);

    { 溜めと枠をすべて捨て、通し番号を 0 に戻す。
      同じ音を流し直すときに使う (X-06 Replay / Z-05)。
      **前の流れを読んでいた読み手には srReset で知らせる。** }
    procedure Reset;

    { 新しい読み手。**いまより後の枠**から読む (過去は返さない)。 }
    function NewReader: TSpectrumReader;

    { 次の 1 枠を取り出す。ABins は BinCount 個以上を受け取れること。
      srOk のときだけ ABins が埋まる。 }
    function TryRead(var AReader: TSpectrumReader;
      var ABins: array of Double; out AInfo: TSpectrumFrameInfo): TSpectrumReadResult;

    { bin の中心周波数 [Hz]。 }
    function BinFrequency(ABin: Integer): Double;
    { 周波数に最も近い bin。範囲外は端に丸める。 }
    function FrequencyToBin(AHz: Double): Integer;
    { bin 1 本の幅 [Hz]。 }
    function BinWidthHz: Double;

    { 窓の等価雑音帯域幅 [bin]。周期形なので値は FFT 長に依らず
      矩形 1.0 / Hann 1.5 / Hamming 1.3628 / Blackman 1.7268 ちょうど。窓を掛けると bin 1 本が拾う雑音の帯域が広がるので、
      雑音を扱うときはこれで割る。 }
    property NoiseBandwidthBins: Double read FEnbwBins;
    { 同じものを Hz で。 }
    function NoiseBandwidthHz: Double;
    { bin のパワーを **1 Hz あたりの電力密度** にする。
      窓と FFT 長に依らない量になるので、雑音床の推定はこちらを使う
      (Phase 3 Noise Estimator / Reception State Estimator)。 }
    function PowerToDensity(APower: Double): Double;

    property FftSize: Integer read FFftSize;
    property BinCount: Integer read FBinCount;
    property Hop: Integer read FHop;
    property SampleRate: Integer read FSampleRate;
    property WindowKind: TSpectrumWindow read FWindowKind;
    property FrameCapacity: Integer read FFrameCapacity;
    { これまでに作った枠の数。 }
    function FramesProduced: Int64;
    { これまでに入れたサンプル数。 }
    function SamplesFed: Int64;
    { 1 枠あたりの時間 [秒]。 }
    function FrameSeconds: Double;
  end;

{ 線形パワーを dB にする。表示のための変換なので、使う側が呼ぶ。
  0 を log に入れないよう下限を置く。 }
function PowerToDb(APower: Double): Double;

function SpectrumWindowName(AKind: TSpectrumWindow): string;
function SpectrumReadResultName(AResult: TSpectrumReadResult): string;

implementation

const
  { dB 変換の下限。-200 dB 相当。 }
  DB_FLOOR = 1.0E-20;

function PowerToDb(APower: Double): Double;
begin
  if APower < DB_FLOOR then
    APower := DB_FLOOR;
  Result := 10.0 * Log10(APower);
end;

function SpectrumWindowName(AKind: TSpectrumWindow): string;
begin
  case AKind of
    swRectangular: Result := '矩形';
    swHann:        Result := 'Hann';
    swHamming:     Result := 'Hamming';
    swBlackman:    Result := 'Blackman';
  else
    Result := '?';
  end;
end;

function SpectrumReadResultName(AResult: TSpectrumReadResult): string;
begin
  case AResult of
    srOk:     Result := '取得';
    srNoData: Result := '新しい枠なし';
    srMissed: Result := '追い越された';
    srReset:  Result := '流し直された';
  else
    Result := '?';
  end;
end;

function TSpectrumFrameInfo.Describe: string;
begin
  Result := Format('枠 #%d (先頭 %d サンプル)', [Sequence, StartSample]);
  if MissedFrames > 0 then
    Result := Result + Format(' / %d 枠を飛ばした', [MissedFrames]);
end;

{ TSpectrumService }

constructor TSpectrumService.Create(AFftSize, ASampleRate, AHop: Integer;
  AWindowKind: TSpectrumWindow; AFrameCapacity: Integer);
begin
  inherited Create;

  if not IsPowerOfTwo(AFftSize) or (AFftSize < 16) then
    raise ESpectrumError.CreateFmt(
      'FFT 長は 16 以上の 2 の冪乗である必要があります (指定: %d)', [AFftSize]);
  if ASampleRate <= 0 then
    raise ESpectrumError.CreateFmt(
      '標本化周波数が不正です (%d)', [ASampleRate]);

  FFftSize := AFftSize;
  FBinCount := AFftSize div 2 + 1;
  FSampleRate := ASampleRate;

  if AHop <= 0 then
    AHop := AFftSize div 4;
  if AHop > AFftSize then
    raise ESpectrumError.CreateFmt(
      '送り幅が FFT 長を超えています (%d > %d)。窓が飛び飛びになり、' +
      '間の音がどの枠にも入らなくなります。', [AHop, AFftSize]);
  FHop := AHop;

  if AFrameCapacity < 2 then
    raise ESpectrumError.CreateFmt(
      '枠は 2 つ以上保持する必要があります (指定: %d)', [AFrameCapacity]);
  FFrameCapacity := AFrameCapacity;

  FWindowKind := AWindowKind;
  SetLength(FWindow, FFftSize);
  BuildWindow;

  SetLength(FAccum, FFftSize);
  SetLength(FWork, FFftSize);
  SetLength(FFrames, Int64(FFrameCapacity) * FBinCount);

  Reset;
end;

procedure TSpectrumService.BuildWindow;
var
  i: Integer;
  t, sumSq: Double;
begin
  { 窓の総和と二乗和を同時に出す。
    総和は振幅の正規化に、二乗和は雑音の正規化 (ENBW) に使う。 }
  FWindowSum := 0;
  sumSq := 0;
  for i := 0 to FFftSize - 1 do
  begin
    { 分母は N-1 ではなく **N**。周期形 (DFT-even) の窓である。
      N-1 の対称形は FIR フィルタ設計のための形で、スペクトル解析に使うと
      窓自身のスペクトルが 3 本に収まらず、ENBW も 1.5 ちょうどにならない
      (N=1024 で 1.5015)。周期形なら bin 中心の正弦波の漏れが厳密に隣 1 本
      までに収まり、ENBW は窓の種類だけで決まる定数になる。
      Phase 3 の Noise Estimator はその定数で較正するので、ここは厳密に。 }
    t := 2 * Pi * i / FFftSize;
    case FWindowKind of
      swRectangular: FWindow[i] := 1.0;
      swHann:        FWindow[i] := 0.5 - 0.5 * Cos(t);
      swHamming:     FWindow[i] := 0.54 - 0.46 * Cos(t);
      swBlackman:    FWindow[i] := 0.42 - 0.5 * Cos(t) + 0.08 * Cos(2 * t);
    end;
    FWindowSum := FWindowSum + FWindow[i];
    sumSq := sumSq + FWindow[i] * FWindow[i];
  end;
  if FWindowSum <= 0 then
    raise ESpectrumError.Create('窓の総和が 0 以下です。');

  { 等価雑音帯域幅 [bin] = N * Σw^2 / (Σw)^2。
    窓を掛けたことで bin 1 本が拾う白色雑音が何 bin ぶんに相当するか。
    矩形窓なら 1 になる (定義どおり)。 }
  FEnbwBins := FFftSize * sumSq / (FWindowSum * FWindowSum);
end;

procedure TSpectrumService.Reset;
var
  i: Integer;
begin
  { 世代を進める。通し番号を 0 に戻す以上、前の流れの位置を持ったままの
    読み手は行き場を失う —— 黙って餓死させず srReset で知らせるための印。
    コンストラクタからも呼ばれるので、ここが 0 -> 1 の初期化も兼ねる。 }
  Inc(FEpoch);
  FFill := 0;
  FTotalSamples := 0;
  FReserved := 0;
  FCommitted := 0;
  for i := 0 to High(FAccum) do
    FAccum[i] := 0;
  for i := 0 to High(FFrames) do
    FFrames[i] := 0;
end;

procedure TSpectrumService.EmitFrame;
var
  i, slot: Integer;
  base: Int64;
  scale, re, im, p: Double;
begin
  { 窓を掛けて複素数に載せる。虚部は 0 (入力は実数)。 }
  for i := 0 to FFftSize - 1 do
    FWork[i] := CplxMake(FAccum[i] * FWindow[i], 0);

  { 共有プランを通す。係数表は他の利用者と共有される (X-05)。 }
  ComplexFFT(FWork);

  { --- 予約 ---
    書く前に「ここまで潰す」と宣言する。読み手はこれを見て、自分の位置が
    まだ生きているかを保守的に判断する (AudioHistory と同じ順序。
    書いてから宣言すると、その隙に読み手が潰れた枠を生きていると誤認する)。 }
  Inc(FReserved);
  WriteBarrier;

  slot := Integer((FReserved - 1) mod FFrameCapacity);
  base := Int64(slot) * FBinCount;

  { 振幅の正規化。窓つき DFT では、振幅 A の正弦波が bin k に
      |X[k]| = A * Σw / 2
    として現れる。したがって A = 2|X[k]| / Σw、正弦波の平均電力は
    A^2/2 = 2|X[k]|^2 / (Σw)^2 になる。
    直流とナイキストは片側だけなので 2 倍しない。 }
  scale := 2.0 / (FWindowSum * FWindowSum);
  for i := 0 to FBinCount - 1 do
  begin
    re := FWork[i].Re;
    im := FWork[i].Im;
    p := (re * re + im * im) * scale;
    if (i = 0) or (i = FFftSize div 2) then
      p := p * 0.5;
    FFrames[base + i] := p;
  end;

  { --- 確定 --- }
  WriteBarrier;
  FCommitted := FReserved;
end;

procedure TSpectrumService.Feed(const ABuf: array of Double; ALen: Integer);
var
  i, n, keep: Integer;
begin
  if ALen <= 0 then Exit;
  if ALen > Length(ABuf) then
    ALen := Length(ABuf);

  i := 0;
  while i < ALen do
  begin
    { 溜めに入る分だけ入れる。 }
    n := FFftSize - FFill;
    if n > ALen - i then
      n := ALen - i;
    Move(ABuf[i], FAccum[FFill], n * SizeOf(Double));
    Inc(FFill, n);
    Inc(i, n);
    Inc(FTotalSamples, n);

    if FFill < FFftSize then
      Break;

    EmitFrame;

    { hop だけ進める。残りは次の窓に持ち越す (重ねるため)。
      Move は確保しない。 }
    keep := FFftSize - FHop;
    if keep > 0 then
      Move(FAccum[FHop], FAccum[0], keep * SizeOf(Double));
    FFill := keep;
  end;
end;

function TSpectrumService.NewReader: TSpectrumReader;
begin
  { いまより後の枠から読む。開いた瞬間に過去が滝のように出てこないように。 }
  Result.NextSeq := FCommitted;
  Result.Epoch := FEpoch;
  ReadBarrier;
end;

function TSpectrumService.TryRead(var AReader: TSpectrumReader;
  var ABins: array of Double; out AInfo: TSpectrumFrameInfo): TSpectrumReadResult;
var
  committed, reserved, oldest, base: Int64;
  slot, i: Integer;
begin
  AInfo.Sequence := AReader.NextSeq;
  AInfo.StartSample := 0;
  AInfo.MissedFrames := 0;

  if Length(ABins) < FBinCount then
    raise ESpectrumError.CreateFmt(
      '受け皿が足りません (要求 %d / 受け皿 %d)', [FBinCount, Length(ABins)]);

  { --- 流し直しの検出 ---
    Reset で通し番号が 0 に戻ると、前の流れの位置 (例えば 9) は
    新しい流れの committed (例えば 3) より先にいることになり、
    読み手は **黙って何も返されないまま**待ち続ける。しかも新しい流れが
    10 枠を超えた瞬間、何事もなかったように途中から読み始めてしまう。
    統計を溜めている側にとってはこれが最悪で、二つの録音が混ざる。
    だから世代が違えば、まず「流し直された」と言う。
    溜めた統計を捨てる判断は使う側にしかできない (X-06 Replay)。 }
  if AReader.Epoch <> FEpoch then
  begin
    AReader.Epoch := FEpoch;
    AReader.NextSeq := 0;
    AInfo.Sequence := 0;
    Exit(srReset);
  end;

  committed := FCommitted;
  ReadBarrier;

  if AReader.NextSeq >= committed then
    Exit(srNoData);

  { 上書きの判定は予約で行う。確定で判定すると、書き込み中の枠を
    まだ生きていると誤認する。 }
  reserved := FReserved;
  ReadBarrier;
  oldest := reserved - FFrameCapacity;
  if oldest < 0 then oldest := 0;

  if AReader.NextSeq < oldest then
  begin
    AInfo.MissedFrames := oldest - AReader.NextSeq;
    AReader.NextSeq := oldest;
    Exit(srMissed);
  end;

  slot := Integer(AReader.NextSeq mod FFrameCapacity);
  base := Int64(slot) * FBinCount;
  for i := 0 to FBinCount - 1 do
    ABins[i] := FFrames[base + i];

  { --- 読み取りが破れていないかの確認 ---
    複写している間に書き手が回り込んで、この枠を潰していないか。
    潰していれば、いま手元にあるのは継ぎはぎである。 }
  ReadBarrier;
  reserved := FReserved;
  if AReader.NextSeq < reserved - FFrameCapacity then
  begin
    oldest := reserved - FFrameCapacity;
    AInfo.MissedFrames := oldest - AReader.NextSeq;
    AReader.NextSeq := oldest;
    Exit(srMissed);
  end;

  AInfo.Sequence := AReader.NextSeq;
  { この枠の窓の先頭が、通算で何サンプル目か。
    枠 s の窓は [s*hop, s*hop + FftSize) を覆う。 }
  AInfo.StartSample := AReader.NextSeq * FHop;
  Inc(AReader.NextSeq);
  Result := srOk;
end;

function TSpectrumService.BinFrequency(ABin: Integer): Double;
begin
  Result := ABin * FSampleRate / FFftSize;
end;

function TSpectrumService.FrequencyToBin(AHz: Double): Integer;
begin
  Result := Round(AHz * FFftSize / FSampleRate);
  if Result < 0 then Result := 0;
  if Result > FBinCount - 1 then Result := FBinCount - 1;
end;

function TSpectrumService.BinWidthHz: Double;
begin
  Result := FSampleRate / FFftSize;
end;

function TSpectrumService.NoiseBandwidthHz: Double;
begin
  Result := FEnbwBins * BinWidthHz;
end;

function TSpectrumService.PowerToDensity(APower: Double): Double;
begin
  Result := APower / NoiseBandwidthHz;
end;

function TSpectrumService.FramesProduced: Int64;
begin
  Result := FCommitted;
end;

function TSpectrumService.SamplesFed: Int64;
begin
  Result := FTotalSamples;
end;

function TSpectrumService.FrameSeconds: Double;
begin
  Result := FHop / FSampleRate;
end;

end.
