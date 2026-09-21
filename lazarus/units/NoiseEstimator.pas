{ ============================================================================
  NoiseEstimator.pas

  雑音床の共有サービス (X-05 / SPC-002)。Phase 3 Adaptive Receiver の
  最初の部品である。

  なぜ共有なのか
  ----------------------------------------------------------------------------
  Phase 3 からは復調戦略が複数並ぶ (Algorithm Portfolio)。Squelch も AGC も
  Confidence も「いまの雑音床」を土台にする。**各戦略が自前で雑音を測ると、
  同じ音に対して別々の雑音床を持つ**ことになり、戦略どうしの比較が成り立たない。
  FFT の係数表と Spectrum を共有サービスにしたのと同じ理由である。

  どう測るのか
  ----------------------------------------------------------------------------
  平均ではなく**分位点**を使う。平均は信号に引きずられる ―― 強い信号が
  1 本立っただけで雑音床が持ち上がり、「S/N が下がった」ことになってしまう。
  帯域の大半が雑音であるかぎり、分位点は信号が何本立っていても動かない。

  そのままでは平均より小さい値になるので、**較正する**。白色雑音の
  スペクトルでは各 bin の電力が指数分布に従い、その p 分位点は

      quantile(p) = -ln(1 - p) * mean

  になる。したがって mean = quantile(p) / (-ln(1-p))。中央値 (p=0.5) なら
  ln2 = 0.693 で割る ―― 1.59 dB の持ち上げである。この係数を入れないと
  雑音床を 1.59 dB 低く見積もり、S/N をそのぶん良く申告してしまう。

  較正が効いていることは試験で見る。既知の分散の白色雑音を入れて、
  SPC-001 が固定した理論値 2*sigma^2/Fs に載ることを確かめる。

  取りこぼしを黙って飲まない
  ----------------------------------------------------------------------------
  スペクトルの枠を取りこぼすと、**偏った標本で雑音床を作る**ことになる。
  表示なら困らないが、統計を取る側は偏りに気づけない。だから Update は
  取りこぼした枠数と流し直しを申告する。捨てるか続けるかは使う側が決める
  (AudioRing / SpectrumService と同じ規律)。

  スレッド
  ----------------------------------------------------------------------------
  Update は 1 つのスレッドから呼ぶ (スペクトルを回しているスレッド)。
  問い合わせ (NoiseDensity ほか) は他のスレッドから読んでよいが、値は
  **ある時点のもの**であって、読んだ瞬間に更新が走っているかもしれない。
  雑音床は秒単位で動く量なので、それで困る使い方はしない。

  ここに無いもの
  ----------------------------------------------------------------------------
  QSB / QRM / Impulse / Frequency offset といった受信状態の残りは
  Reception State Estimator の領分で、別の要求になる。ここは**雑音床と、
  そこから出る帯域 S/N** だけを持つ。
  ============================================================================ }
unit NoiseEstimator;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemTypes, ModemDSP, SpectrumService;

const
  { 既定の分位点。中央値。帯域の半分以上が信号で埋まると持ち上がるが、
    短波でそこまで埋まることはまず無い。埋まる場面 (コンテストの
    混雑帯) を想定するなら下げる。 }
  NOISE_DEFAULT_PERCENTILE = 0.5;

  { 既定のならし長 [枠]。雑音床は秒単位でしか動かないので、
    1 枠ごとの揺らぎは潰してよい。8 枠は 8 kHz / hop 2048 で約 2 秒。 }
  NOISE_DEFAULT_SMOOTH = 8;

type
  ENoiseEstimatorError = class(Exception);

  { Update の結果。取りこぼしと流し直しを申告するためにある。 }
  TNoiseUpdateInfo = record
    Frames: Integer;       // 今回取り込んだ枠数
    MissedFrames: Int64;   // 取りこぼした枠数 (0 なら連続している)
    WasReset: Boolean;     // 流し直しをまたいだ
    function Describe: string;
  end;

  TNoiseEstimator = class
  private
    FSpectrum: TSpectrumService;
    FReader: TSpectrumReader;
    FBins: array of Double;
    FWork: array of Double;     // 分位点を取る作業用 (その場で並べ替える)
    FLoBin, FHiBin: Integer;
    FPercentile: Double;
    FCorrection: Double;        // -ln(1-p)
    FSmooth: TLowPass3;
    FWeight: Double;
    FDensity: Double;           // ならした雑音の電力密度
    FRaw: Double;               // 直近 1 枠の推定 (診断用)
    FFrames: Int64;
    FReady: Boolean;
    procedure SetPercentile(AValue: Double);
  public
    constructor Create(ASpectrum: TSpectrumService;
      APercentile: Double = NOISE_DEFAULT_PERCENTILE;
      ASmoothFrames: Integer = NOISE_DEFAULT_SMOOTH);

    { 推定を初期に戻す。読み位置もスペクトルの最新に付け直す。 }
    procedure Reset;

    { スペクトルから読めるだけ読んで推定を進める。確保しない (X-04)。 }
    function Update(out AInfo: TNoiseUpdateInfo): Integer;

    { 雑音の片側電力密度 [1 Hz あたり]。較正済み。
      まだ 1 枠も読んでいなければ 0。 }
    function NoiseDensity: Double;
    function NoiseDensityDb: Double;
    { ならす前の、直近 1 枠ぶんの推定。診断用。 }
    function RawDensity: Double;

    { 指定の帯域に含まれる雑音の電力。 }
    function NoisePowerInBand(ALoHz, AHiHz: Double): Double;
    { 指定の帯域の S/N [dB]。帯域内の電力の合計から雑音ぶんを引いて比を取る。
      信号が雑音に埋もれていれば負になる。 }
    function SnrInBandDb(ALoHz, AHiHz: Double): Double;

    { 分位点。運用中に変えてよい (混雑帯では下げる)。 }
    property Percentile: Double read FPercentile write SetPercentile;
    { 較正係数 -ln(1-p)。試験と診断のため。 }
    property Correction: Double read FCorrection;
    { 取り込んだ枠数。 }
    function FramesUsed: Int64;
    { 1 枠でも取り込んだか。False の間は雑音床を使ってはいけない。 }
    property Ready: Boolean read FReady;
    property Spectrum: TSpectrumService read FSpectrum;
    { 雑音を測る bin の範囲。直流とナイキストは外してある。 }
    property LowBin: Integer read FLoBin;
    property HighBin: Integer read FHiBin;
  end;

implementation

function TNoiseUpdateInfo.Describe: string;
begin
  Result := Format('枠 %d / 取りこぼし %d%s',
    [Frames, MissedFrames, BoolToStr(WasReset, ' / 流し直し', '')]);
end;

constructor TNoiseEstimator.Create(ASpectrum: TSpectrumService;
  APercentile: Double; ASmoothFrames: Integer);
begin
  inherited Create;
  if ASpectrum = nil then
    raise ENoiseEstimatorError.Create('スペクトルサービスが要ります');
  if ASmoothFrames < 1 then
    raise ENoiseEstimatorError.CreateFmt(
      'ならし長は 1 以上です (指定 %d)', [ASmoothFrames]);
  FSpectrum := ASpectrum;

  { 直流とナイキストは片側しか折り返さないので電力が半分になる。
    混ぜると分位点がわずかに下がる。2 本だけのことだが、較正を
    謳う以上は外しておく。 }
  FLoBin := 1;
  FHiBin := FSpectrum.BinCount - 2;
  if FHiBin < FLoBin then
    raise ENoiseEstimatorError.Create('bin が少なすぎます');

  SetLength(FBins, FSpectrum.BinCount);
  SetLength(FWork, FHiBin - FLoBin + 1);
  FWeight := 1.0 / ASmoothFrames;
  SetPercentile(APercentile);
  Reset;
end;

procedure TNoiseEstimator.SetPercentile(AValue: Double);
begin
  if (AValue <= 0) or (AValue >= 1) then
    raise ENoiseEstimatorError.CreateFmt(
      '分位点は 0 と 1 の間です (指定 %.3f)', [AValue]);
  FPercentile := AValue;
  { 指数分布の p 分位点は -ln(1-p) * 平均。割り戻して平均に直す。 }
  FCorrection := -Ln(1 - AValue);
end;

procedure TNoiseEstimator.Reset;
begin
  { 読み位置を付け直す。前の流れの枠を混ぜない。 }
  FReader := FSpectrum.NewReader;
  FSmooth.Reset(0);
  FDensity := 0;
  FRaw := 0;
  FFrames := 0;
  FReady := False;
end;

function TNoiseEstimator.Update(out AInfo: TNoiseUpdateInfo): Integer;
var
  info: TSpectrumFrameInfo;
  res: TSpectrumReadResult;
  i, n: Integer;
  q, mean: Double;
begin
  AInfo.Frames := 0;
  AInfo.MissedFrames := 0;
  AInfo.WasReset := False;

  repeat
    res := FSpectrum.TryRead(FReader, FBins, info);
    case res of
      srReset:
        begin
          { 流れが変わった。溜めた推定は前の音のものなので捨てる。
            捨てたことは呼び手に伝える ―― 統計を取っている側は、
            自分の材料が切れたことを知らなければならない。 }
          FSmooth.Reset(0);
          FDensity := 0;
          FRaw := 0;
          FFrames := 0;
          FReady := False;
          AInfo.WasReset := True;
        end;
      srMissed:
        Inc(AInfo.MissedFrames, info.MissedFrames);
      srOk:
        begin
          n := 0;
          for i := FLoBin to FHiBin do
          begin
            FWork[n] := FBins[i];
            Inc(n);
          end;
          { その場で並べ替える。確保しない。 }
          q := PercentileInPlace(FWork, n, FPercentile);
          mean := q / FCorrection;
          FRaw := FSpectrum.PowerToDensity(mean);
          FSmooth.Process(FRaw, FWeight);
          FDensity := FSmooth.Output;
          Inc(FFrames);
          FReady := True;
          Inc(AInfo.Frames);
        end;
    end;
  until res = srNoData;

  Result := AInfo.Frames;
end;

function TNoiseEstimator.NoiseDensity: Double;
begin
  Result := FDensity;
end;

function TNoiseEstimator.NoiseDensityDb: Double;
begin
  Result := PowerToDb(FDensity);
end;

function TNoiseEstimator.RawDensity: Double;
begin
  Result := FRaw;
end;

function TNoiseEstimator.NoisePowerInBand(ALoHz, AHiHz: Double): Double;
begin
  if AHiHz < ALoHz then
    raise ENoiseEstimatorError.CreateFmt(
      '帯域の上下が逆です (%.1f..%.1f Hz)', [ALoHz, AHiHz]);
  Result := FDensity * (AHiHz - ALoHz);
end;

function TNoiseEstimator.SnrInBandDb(ALoHz, AHiHz: Double): Double;
var
  lo, hi, i: Integer;
  total, noise, signal: Double;
begin
  if not FReady then
    raise ENoiseEstimatorError.Create(
      'まだ雑音床が測れていません (Update が 1 枠も取り込んでいない)');

  { いまの枠をもう一度読むのではなく、**直近に取り込んだ枠**をそのまま
    使う ―― FBins には Update が最後に読んだ内容が残っている。
    別の読み手を作って読み直すと、時刻の違う枠を雑音床と突き合わせる
    ことになる。 }
  lo := FSpectrum.FrequencyToBin(ALoHz);
  hi := FSpectrum.FrequencyToBin(AHiHz);
  if lo < 0 then lo := 0;
  if hi > FSpectrum.BinCount - 1 then hi := FSpectrum.BinCount - 1;
  if hi < lo then
    raise ENoiseEstimatorError.CreateFmt(
      '帯域が bin に落ちません (%.1f..%.1f Hz)', [ALoHz, AHiHz]);

  total := 0;
  for i := lo to hi do
    total := total + FBins[i];

  { 帯域内の雑音ぶん。bin 数 x 1 bin あたりの雑音電力。
    1 bin あたりの雑音電力は 密度 x ENBW[Hz] である。 }
  noise := FDensity * FSpectrum.NoiseBandwidthHz * (hi - lo + 1);
  signal := total - noise;
  if signal <= 0 then
  begin
    { 信号が雑音に埋もれている。0 を割らないよう、測れる下限を返す。 }
    Result := -99.0;
    Exit;
  end;
  Result := PowerToDb(signal / noise);
end;

function TNoiseEstimator.FramesUsed: Int64;
begin
  Result := FFrames;
end;

end.
