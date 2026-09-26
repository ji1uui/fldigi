{ ============================================================================
  AdaptiveSquelch.pas

  雑音床から自動的にしきい値を決めるスケルチ (§12 Phase 3 Adaptive
  Squelch / MDM-015)。Reception State Estimator (SPC-003) の直後にある
  部品である。

  何を「適応的」と呼ぶのか
  ----------------------------------------------------------------------------
  旧来のスケルチは「S メーターがここを超えたら開く」という**絶対値**の
  しきい値だった。帯域の雑音床が上がれば (夜間の混雑、雷雑音等)、
  そのたびに利用者が手で締め直す必要がある。

  ここでのしきい値は **帯域 S/N (雑音床からの相対値)** に対して掛ける。
  `TReceptionStateEstimator.State.SnrDb` はすでに「いまの雑音床から
  何 dB 高いか」を返す ―― 雑音床が動けば `SnrDb` の計算そのものが
  ついてくる (SPC-002/SPC-003)。だから**固定のマージンを帯域 S/N に
  掛けるだけで、結果として雑音床の変化に自動追随する**。これが
  「適応的」の中身であって、マージンの値自体を動かす仕組みではない。

  マージンは実測で決めた
  ----------------------------------------------------------------------------
  マージンが小さすぎれば雑音だけで開いてしまう (過検出)。大きすぎれば
  弱いが復号できるはずの信号まで閉じてしまう (過抑制)。実測 (既定の
  FFT/hop/帯域幅、白色雑音):

      条件                            実測
      雑音のみ (5000 回)              SnrInBandDb の最大 -2.175 dB
      真の S/N 0 dB (帯域内)          SnrInBandDb 平均 -0.50 dB
      真の S/N 3 dB                  SnrInBandDb 平均 +2.45 dB
      真の S/N 6 dB 以上              誤差 1 dB 未満で追随

  雑音のみで 5000 回のうち 1 回も 0 dB を超えなかった (test_noise の
  分位点較正と同じ実測の裏づけ)。既定マージンを **3 dB** にしたのは、
  雑音のみの実測最大値に 5 dB 近い余裕を持たせつつ、まだ復号の見込みが
  ある S/N (3 dB 前後) では開くようにするためである。

  雑音床が測れていないうちは開けたままにする (fail-open)
  ----------------------------------------------------------------------------
  スケルチの役目は「雑音だと確信できたら黙らせる」ことであって、
  「確信できるまで黙らせる」ことではない。まだ雑音床が測れていない
  (`ReceptionState.HasSnr = False`) あいだに閉じてしまうと、起動直後の
  数秒間、本物の信号があっても黙り続ける。PSK の `Squelch <= 0` が
  「スケルチなし」を意味するのと同じ考え方で、**測れていなければ
  開けたまま**にする。

  各モデムの Squelch / Metric への配線はまだ無い
  ----------------------------------------------------------------------------
  `TCustomModem.Squelch` / `Metric` の既存の約束は、PSK が実装している
  「0..100 の位相整合度」を利用者が手で締める仕組みである。ここで作った
  `IsOpen` は **帯域 S/N [dB]** という別の尺度で判断するので、そのまま
  `Squelch` に代入してよい値ではない (単位が違う)。

  さらに調べると、**Olivia は `mcSquelch` を Capabilities に立てている
  のに、`Squelch` / `Metric` のどちらも実際には読んでいない**
  (`FSync.Threshold` という別のしきい値を持つが、`Squelch` からは
  つながっていない)。これは今回の変更より前からある不整合で、直す
  ならず者の推測 (dB とブロック内 S/N 比をどう対応づけるか) をここで
  持ち込みたくない。**この一件はここで見つけた事実として記録するだけに
  留め、直接の配線はまだ行わない。**

  したがって `TAdaptiveSquelch` はいまのところ独立した判断サービスで、
  「いま開けるべきか」を答える。どのモデムの Squelch をどう動かすかは
  Strategy Manager (MDM-017) 側の役目として残す。
  ============================================================================ }
unit AdaptiveSquelch;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, ReceptionState;

const
  { 既定のマージン [dB]。ユニット冒頭の実測を参照。 }
  ADAPTIVE_SQUELCH_DEFAULT_MARGIN_DB = 3.0;

type
  EAdaptiveSquelchError = class(Exception);

  TAdaptiveSquelch = class
  private
    FState: TReceptionStateEstimator;
    FMarginDb: Double;
    FOpenCount: Int64;
    FClosedCount: Int64;
    FUnknownCount: Int64;
    procedure SetMarginDb(AValue: Double);
  public
    { AState: 帯域 S/N を持つ Reception State (SPC-003)。**所有しない** ――
      解放は呼び出し側の責務 (NoiseEstimator を ReceptionState が
      所有しないのと同じ分担)。 }
    constructor Create(AState: TReceptionStateEstimator;
      AMarginDb: Double = ADAPTIVE_SQUELCH_DEFAULT_MARGIN_DB);

    { 診断用の回数を捨てる。判断そのもの (IsOpen) は ReceptionState の
      いまの値だけで決まる純粋な関数なので、状態は持ち直さない。 }
    procedure Reset;

    { いま開けるべきか。
        - 帯域 S/N が測れていなければ True (fail-open。ユニット冒頭を参照)
        - マージンが 0 以下なら常に True (スケルチなし。PSK の Squelch と同じ約束)
        - それ以外は SnrDb > MarginDb
      呼ぶたびに診断用の回数を数える。確保しない (X-04)。 }
    function IsOpen: Boolean;

    { マージン [dB]。0 以下は「スケルチなし」。運用中に変えてよい。 }
    property MarginDb: Double read FMarginDb write SetMarginDb;

    property OpenCount: Int64 read FOpenCount;
    property ClosedCount: Int64 read FClosedCount;
    { 帯域 S/N が測れておらず fail-open で通した回数。 }
    property UnknownCount: Int64 read FUnknownCount;
  end;

implementation

constructor TAdaptiveSquelch.Create(AState: TReceptionStateEstimator;
  AMarginDb: Double);
begin
  inherited Create;
  if AState = nil then
    raise EAdaptiveSquelchError.Create('ReceptionStateEstimator が要ります');
  FState := AState;
  FMarginDb := AMarginDb;
  Reset;
end;

procedure TAdaptiveSquelch.Reset;
begin
  FOpenCount := 0;
  FClosedCount := 0;
  FUnknownCount := 0;
end;

procedure TAdaptiveSquelch.SetMarginDb(AValue: Double);
begin
  FMarginDb := AValue;
end;

function TAdaptiveSquelch.IsOpen: Boolean;
var
  st: TReceptionState;
begin
  if FMarginDb <= 0 then
  begin
    Result := True;
    Inc(FOpenCount);
    Exit;
  end;

  st := FState.State;
  if not st.HasSnr then
  begin
    { 雑音床がまだ測れていない。開けたままにする (fail-open)。 }
    Result := True;
    Inc(FUnknownCount);
    Exit;
  end;

  Result := st.SnrDb > FMarginDb;
  if Result then Inc(FOpenCount) else Inc(FClosedCount);
end;

end.
