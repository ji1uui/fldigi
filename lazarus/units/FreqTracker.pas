{ ============================================================================
  FreqTracker.pas

  周波数追尾 (AFC) の共通部分 (MDM-006)。

  なぜ共通にするのか
  ----------------------------------------------------------------------------
  誤差の **測り方** はモードごとに違う。PSK は記号間の位相差から、RTTY は
  マーク音の位相の進みから、MFSK や Olivia はトーンの位置から測る。
  しかし測ったあとの **効かせ方** は同じである ――

    - 指令された周波数からどれだけ離れたかを持つ (離れた量そのもの)
    - 1 回の測定を全部は効かせない (雑音で飛ぶ)
    - どこまでも離れてよいわけではない (隣の信号へ乗り移る)
    - 指令が変わったら、それまでのずれは無効になる
    - 流し直しでは捨てる (Z-05。同じ音から同じ結果)

  この 5 つをモードごとに書くと、どれか 1 つを書き忘れる。実際 RTTY の
  AFC は「どこまでも離れてよい」形になっていた (fldigi もそう)。

  ずれは **指令からの差** で持つ
  ----------------------------------------------------------------------------
  fldigi は `frequency -= freqerr` と、いま見ている周波数を直接動かす。
  この形だと「どれだけ離れたか」がどこにも残らないので、上限を掛けるにも
  元へ戻すにも、別に指令値を憶えておかなければならない。

  ここでは **ずれ (Offset) を持ち、周波数は指令 + ずれ で出す**。
  上限はずれに掛ける。元へ戻すのはずれを捨てるだけである。
  `TCustomModem.TrackFreq` / `RestoreCommandedFreq` の分担と同じ考え方で、
  そちらが「指令値を壊さない」ことを保証し、こちらが「ずれの量」を持つ。

  送信も動く
  ----------------------------------------------------------------------------
  `TCustomModem.SetFreq` は周波数ロックが無ければ送信周波数も動かす。
  つまり AFC は **こちらの送信周波数も動かす**。相手に合わせて返すのだから
  それでよいのだが、際限なく動いては困る (Transmit は fail-safe)。
  ずれの上限は、受信の乗り移り防止であると同時に **送信が指令からどこまで
  離れうるかの上限**でもある。

  ここに無いもの
  ----------------------------------------------------------------------------
  - **入/切**。持つ側 (モデム) の持ち物にする。切ったときに「そこで止める」
    のか「指令へ戻す」のかはモードの運用の話で、追尾の仕組みではない。
  - **ドリフト率** (§6.1 の drift)。時間の刻みを持ち込むことになるし、
    受信状態の推定は Reception State Estimator の領分である。ずれの時系列は
    Offset を読めば作れる。
  ============================================================================ }
unit FreqTracker;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math;

type
  EFreqTrackerError = class(Exception);

  TFreqTracker = record
  private
    FBase: Double;        // ずれの基準にしている指令周波数 [Hz]
    FHasBase: Boolean;    // まだ基準を取っていない
    FOffset: Double;      // 指令からのずれ [Hz]
    FRange: Double;       // ずれの上限 [Hz] (両側)
    FGain: Double;        // 1 回の測定を効かせる割合
    FLastError: Double;   // 直近に与えられた誤差 [Hz] (診断用)
    FUpdates: Int64;
    FClamps: Int64;       // 上限に当たった回数
    FRebases: Int64;      // 指令が変わってずれを捨てた回数
  public
    { 上限 [Hz] と利得を決める。利得は 0 < g <= 1。
      1 回の測定で誤差の g 倍を効かせるので、1 秒あたり n 回測るなら
      時定数はおよそ 1/(g*n) 秒になる。 }
    procedure Init(ARangeHz, AGain: Double);

    { 利得だけを変える。ずれは残す ―― 運用中に追尾の速さを変えても
      いま合っているところは合ったままであってほしい。 }
    procedure SetGain(AGain: Double);

    { ずれを捨てる。次の Track で基準を取り直す。
      流し直し (RxInit / Restart) で必ず呼ぶ ―― 呼ばないと前の音で
      ついたずれから始まり、同じ音から同じ結果が出ない (Z-05)。 }
    procedure Reset;

    { 指令周波数と、測った誤差 [Hz] を与えて追尾を 1 歩進める。

      AErrHz は **(いま見ている周波数) - (信号の真の周波数)**。
      正なら高いところを見ているので下げる。

      戻り値は **次に見るべき周波数** [Hz] = 指令 + ずれ。
      指令が前回と変わっていれば、その場でずれを捨ててから進める。 }
    function Track(ACommandedHz, AErrHz: Double): Double;

    { 追尾を進めずに、いま見るべき周波数を返す。 }
    function FrequencyFor(ACommandedHz: Double): Double;

    property Offset: Double read FOffset;
    property Range: Double read FRange;
    property Gain: Double read FGain;
    property LastError: Double read FLastError;
    property Updates: Int64 read FUpdates;
    property Clamps: Int64 read FClamps;
    property Rebases: Int64 read FRebases;
    property HasBase: Boolean read FHasBase;
  end;

implementation

procedure TFreqTracker.Init(ARangeHz, AGain: Double);
begin
  if not (ARangeHz > 0) then
    raise EFreqTrackerError.CreateFmt(
      'ずれの上限は正の値です (指定 %.6g)', [ARangeHz]);
  if not ((AGain > 0) and (AGain <= 1)) then
    raise EFreqTrackerError.CreateFmt(
      '利得は 0 より大きく 1 以下です (指定 %.6g)', [AGain]);
  FRange := ARangeHz;
  FGain := AGain;
  Reset;
end;

procedure TFreqTracker.SetGain(AGain: Double);
begin
  if not ((AGain > 0) and (AGain <= 1)) then
    raise EFreqTrackerError.CreateFmt(
      '利得は 0 より大きく 1 以下です (指定 %.6g)', [AGain]);
  FGain := AGain;
end;

procedure TFreqTracker.Reset;
begin
  FBase := 0;
  FHasBase := False;
  FOffset := 0;
  FLastError := 0;
  FUpdates := 0;
  FClamps := 0;
  FRebases := 0;
end;

function TFreqTracker.Track(ACommandedHz, AErrHz: Double): Double;
begin
  if FRange <= 0 then
    raise EFreqTrackerError.Create('Init を呼んでいません');

  { 指令が変わったら、それまでのずれは前の指令に対するものなので捨てる。
    ここで見るのは、モデム側が SetFreq を上書きして追尾と指令を
    取り違える事故を避けるためでもある (TrackFreq は内部で SetFreq を
    呼ぶので、SetFreq 側で捨てると追尾のたびに捨ててしまう)。 }
  if (not FHasBase) or (ACommandedHz <> FBase) then
  begin
    if FHasBase then Inc(FRebases);
    FBase := ACommandedHz;
    FOffset := 0;
    FHasBase := True;
  end;

  FLastError := AErrHz;
  FOffset := FOffset - FGain * AErrHz;

  if FOffset > FRange then
  begin
    FOffset := FRange;
    Inc(FClamps);
  end
  else if FOffset < -FRange then
  begin
    FOffset := -FRange;
    Inc(FClamps);
  end;

  Inc(FUpdates);
  Result := FBase + FOffset;
end;

function TFreqTracker.FrequencyFor(ACommandedHz: Double): Double;
begin
  if FHasBase and (ACommandedHz = FBase) then
    Result := FBase + FOffset
  else
    Result := ACommandedHz;
end;

end.
