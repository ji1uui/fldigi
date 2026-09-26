{ ============================================================================
  ReceptionState.pas

  受信状態推定の共有サービス (§6.1 / SPC-003)。Phase 3 Adaptive Receiver で
  Noise Estimator (SPC-002) の次にある部品である。

  何を集めるのか
  ----------------------------------------------------------------------------
  Baseline §6.1 は受信状態を 9 項目に分ける:

      SNR / Noise floor / QSB / QRM / Impulse noise /
      Frequency offset・drift / Timing error / Distortion / Selective fading

  Strategy Manager や Confidence (§7) はこれを一括りの「いまの受信状態」
  として読みたい。各モデムや共有サービスがばらばらに持っていては、
  同じ音に対して比較できる形にならない ―― Noise Estimator を共有サービスに
  したのと同じ理由である。

  いま埋まっているのは 3 項目だけである
  ----------------------------------------------------------------------------
  **SNR / Noise floor / Frequency offset の 3 つだけを実装する。**
  残り 6 項目 (QSB / QRM / Impulse noise / Timing error / Distortion /
  Selective fading) は測る手段がまだ無い ――

    - QSB (フェージング) には振幅の時系列とその分散が要る
    - QRM (帯域内の他信号) にはスペクトルの複数ピーク検出が要る
    - Impulse noise には短時間の尖度・衝撃検出が要る
    - Timing error は各モデムのビットクロック復元誤差を Evidence 化する
      必要がある (いまはモデム内部に閉じている)
    - Distortion / Selective fading は複数搬送波・帯域内の比較が要る

  無いものを 0 や適当な値で埋めると、Strategy Manager がそれを
  「測った上での 0」と区別できなくなる。DecodeEvidence.HasSnr /
  HasFreqOffset と同じ約束で、**この 3 つが実装のすべてで、残りは
  Has*=False のまま**であることを型で表す。9 項目ぶんの入れ物を
  先に用意しておくのは、あとから項目を足すたびに型を壊さないためである
  (「後段の Phase への配慮」)。

  SNR / Noise floor はどこから来るか
  ----------------------------------------------------------------------------
  どちらも共有の TNoiseEstimator (SPC-002) をそのまま読む。**所有はしない**
  ―― Noise Estimator は複数の戦略が同じ雑音床を見るための共有サービスで、
  ここで解放してしまうと他の読み手を壊す。生成と解放は呼び出し側の責務
  (TSpectrumService の扱いと同じ)。

  SNR には帯域が要る (`SnrInBandDb(lo, hi)`)。どの帯域を見るかは
  「いまどのモードを聞いているか」で決まるので、ここでは持たず
  `SetBand` で外から与える。帯域を一度も設定していなければ SNR は
  「まだ測れない」として Has*=False を返す。

  Frequency offset はどこから来るか
  ----------------------------------------------------------------------------
  モデムの内部を直接読まない。**Evidence 経由**で受け取る
  (`ObserveEvidence`)。DecodeEvidence.HasFreqOffset / FreqOffsetHz は
  ADR-002 が定めた「受信状態を運ぶ唯一の経路」であり、RTTY (AFC の
  周波数誤差) と PSK (MDM-006 の追尾量) がすでにここへ載せている。
  モデムごとに専用の読み出し窓口を作ると、モデムが増えるたびにここも
  増やすことになる ―― Evidence を経由すれば、モデム側が HasFreqOffset を
  立てるだけで自動的にここへ集まる。

  1 回の Evidence をそのまま出すのではなく、DecayAvg でならす。
  Evidence は文字が確定するたびに飛んでくるので、雑音で 1 文字ぶん
  跳ねた値をそのまま「いまの受信状態」と言うと、Strategy Manager が
  ちらつきに反応してしまう。ならし方は PSK の AfcMetric / RTTY の
  FFreqErr と同じ DecayAvg を使う (ModemDSP.pas)。

  HasFreqOffset を立てない Evidence (CW など、周波数情報を持たない
  モデム) は無視する ―― 混ぜると「測っていないのに 0」を平均に
  混入させることになる。

  スレッド
  ----------------------------------------------------------------------------
  ObserveEvidence は Evidence を出す側 (モデムの OnDecode) と同じ
  スレッドから呼ぶ。State の読み出しは他のスレッドから呼んでよいが、
  NoiseEstimator と同じく「ある時点の値」であることに注意する。

  流し直し (Replay / X-06)
  ----------------------------------------------------------------------------
  Reset は **このオブジェクトが持つ周波数のならしだけ** を捨てる。
  共有の NoiseEstimator までは触らない ―― Noise Estimator は複数の
  戦略が共有しているので、1 つの戦略の流し直しで他の戦略の雑音床を
  巻き込んで消してはいけない。雑音床を流し直したいときは、
  NoiseEstimator 自身の Reset を呼び出し側が別に呼ぶ。
  ============================================================================ }
unit ReceptionState;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemDSP, NoiseEstimator, DecodeEvidence;

const
  { 周波数のずれのならし段数。秒単位でしか動かない量なので、
    1 文字ごとの揺らぎは潰してよい。20 は PSK の AfcMetric (50) より
    短く、RTTY の AFC 既定 (medium, 4) より長い ―― 複数モードの
    Evidence が混在しうる場所なので、どちらかに寄せすぎない中間を選んだ。 }
  RECSTATE_DEFAULT_FREQ_SMOOTH = 20;

type
  EReceptionStateError = class(Exception);

  { いまの受信状態の写し。§6.1 の 9 項目ぶんの入れ物を持つが、
    実装済みなのは SNR / NoiseFloor / FreqOffset の 3 つだけである。
    残りは常に Has*=False (測っていない)。 }
  TReceptionState = record
    HasSnr: Boolean;
    SnrDb: Double;
    HasNoiseFloor: Boolean;
    NoiseFloorDb: Double;
    HasQsb: Boolean;
    QsbMetric: Double;
    HasQrm: Boolean;
    QrmMetric: Double;
    HasImpulseNoise: Boolean;
    ImpulseRate: Double;
    HasFreqOffset: Boolean;
    FreqOffsetHz: Double;
    HasTimingError: Boolean;
    TimingErrorMetric: Double;
    HasDistortion: Boolean;
    DistortionMetric: Double;
    HasSelectiveFading: Boolean;
    SelectiveFadingMetric: Double;

    { 診断・ログ用の1行表現 (Z-01 Observability)。測っている項目だけ出す。 }
    function Describe: string;
  end;

  TReceptionStateEstimator = class
  private
    FNoise: TNoiseEstimator;
    FLoHz, FHiHz: Double;
    FHasBand: Boolean;
    FFreqOffset: Double;
    FFreqWeight: Integer;
    FHasFreqOffset: Boolean;
    FFreqObservations: Int64;
    FFreqIgnored: Int64;
  public
    { ANoise: 共有の雑音床サービス (SPC-002)。**所有しない** ―― 解放は
      呼び出し側の責務。 }
    constructor Create(ANoise: TNoiseEstimator;
      AFreqSmooth: Integer = RECSTATE_DEFAULT_FREQ_SMOOTH);

    { 周波数のならしだけを捨てる。NoiseEstimator には触れない
      (共有サービスなので、他の戦略を巻き込まない)。 }
    procedure Reset;

    { SNR を測る帯域。いま聞いているモードの占有帯域を渡す。
      一度も呼んでいなければ SNR は測れない (Has*=False)。 }
    procedure SetBand(ALoHz, AHiHz: Double);

    { モデムの OnDecode から流れてきた Evidence を 1 件反映する。
      HasFreqOffset が立っていない Evidence は無視する
      (測っていないモデムの「0」を混ぜないため)。 }
    procedure ObserveEvidence(const AEvidence: TDecodeEvidence);

    { いまの受信状態の写しを返す。確保しない (X-04)。 }
    function State: TReceptionState;

    { Evidence を反映した回数 (HasFreqOffset が立っていたもの)。 }
    property FreqObservations: Int64 read FFreqObservations;
    { HasFreqOffset が立っていなかったので無視した回数。 }
    property FreqIgnored: Int64 read FFreqIgnored;
    property Noise: TNoiseEstimator read FNoise;
  end;

implementation

function TReceptionState.Describe: string;
var
  s: string;
begin
  s := '';
  if HasSnr then s := s + Format(' SNR=%.1fdB', [SnrDb]);
  if HasNoiseFloor then s := s + Format(' Noise=%.1fdB', [NoiseFloorDb]);
  if HasQsb then s := s + Format(' QSB=%.3f', [QsbMetric]);
  if HasQrm then s := s + Format(' QRM=%.3f', [QrmMetric]);
  if HasImpulseNoise then s := s + Format(' Impulse=%.3f', [ImpulseRate]);
  if HasFreqOffset then s := s + Format(' FreqOff=%.2fHz', [FreqOffsetHz]);
  if HasTimingError then s := s + Format(' Timing=%.3f', [TimingErrorMetric]);
  if HasDistortion then s := s + Format(' Distortion=%.3f', [DistortionMetric]);
  if HasSelectiveFading then
    s := s + Format(' Fading=%.3f', [SelectiveFadingMetric]);
  if s = '' then
    Result := '(未測定)'
  else
    Result := Trim(s);
end;

constructor TReceptionStateEstimator.Create(ANoise: TNoiseEstimator;
  AFreqSmooth: Integer);
begin
  inherited Create;
  if ANoise = nil then
    raise EReceptionStateError.Create('雑音床サービスが要ります');
  if AFreqSmooth < 1 then
    raise EReceptionStateError.CreateFmt(
      'ならし段数は 1 以上です (指定 %d)', [AFreqSmooth]);
  FNoise := ANoise;
  FFreqWeight := AFreqSmooth;
  Reset;
end;

procedure TReceptionStateEstimator.Reset;
begin
  FFreqOffset := 0;
  FHasFreqOffset := False;
  FFreqObservations := 0;
  FFreqIgnored := 0;
  { 帯域の設定は流し直しをまたいでも意味を持つ (聞いているモードは
    変わっていない) ので、ここでは消さない。 }
end;

procedure TReceptionStateEstimator.SetBand(ALoHz, AHiHz: Double);
begin
  if AHiHz < ALoHz then
    raise EReceptionStateError.CreateFmt(
      '帯域の上下が逆です (%.1f..%.1f Hz)', [ALoHz, AHiHz]);
  FLoHz := ALoHz;
  FHiHz := AHiHz;
  FHasBand := True;
end;

procedure TReceptionStateEstimator.ObserveEvidence(
  const AEvidence: TDecodeEvidence);
begin
  if not AEvidence.HasFreqOffset then
  begin
    Inc(FFreqIgnored);
    Exit;
  end;
  if not FHasFreqOffset then
  begin
    { 最初の 1 件はならさず、そのまま基準にする。DecayAvg は初期値 0 から
      ならすと、最初の何回かが実際の値より 0 寄りに出てしまう
      (NoiseEstimator の初期化と同じ考え方)。 }
    FFreqOffset := AEvidence.FreqOffsetHz;
    FHasFreqOffset := True;
  end
  else
    FFreqOffset := DecayAvg(FFreqOffset, AEvidence.FreqOffsetHz, FFreqWeight);
  Inc(FFreqObservations);
end;

function TReceptionStateEstimator.State: TReceptionState;
begin
  FillChar(Result, SizeOf(Result), 0);

  Result.HasNoiseFloor := FNoise.Ready;
  if Result.HasNoiseFloor then
    Result.NoiseFloorDb := FNoise.NoiseDensityDb;

  Result.HasSnr := FNoise.Ready and FHasBand;
  if Result.HasSnr then
    Result.SnrDb := FNoise.SnrInBandDb(FLoHz, FHiHz);

  Result.HasFreqOffset := FHasFreqOffset;
  if Result.HasFreqOffset then
    Result.FreqOffsetHz := FFreqOffset;

  { QSB / QRM / Impulse noise / Timing error / Distortion /
    Selective fading: まだ測る手段が無い。Has*=False のまま
    (ユニット冒頭の説明を参照)。 }
end;

end.
