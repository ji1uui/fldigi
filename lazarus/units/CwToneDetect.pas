{ ============================================================================
  CwToneDetect.pas

  CW の「音が鳴っているか」を判定する検出器。

  なぜ作り直したのか
  ----------------------------------------------------------------------------
  fldigi 由来の判定は、大きさを agc_peak で正規化してから適応閾値と比べる。
  この形には構造的な弱点が 3 つある。

  1. **推定量が育つまで正規化が壊れる。**
     agc_peak を 0 から decayavg(attack=200) で立ち上げるので、最初の
     非ゼロ標本で value/agc_peak がちょうど 200 になる。信号の大きさとは
     無関係な、EMA を 0 で初期化したことの副産物である。

  2. **雑音床が下がらないことがある。**
     noise_floor は value < sig_avg のときしか下がらないが、sig_avg は 0 から
     上へ収束するので、起動直後はこの条件がほとんど成立しない。初期値 1.0 が
     残り、norm_noise が桁違いに大きくなって上下の閾値が逆転する
     (実測で upper=64 / lower=96)。

  3. **「まだ分からない」を表せない。**
     雑音しか無い区間でも必ずどちらかに判定してしまう。fldigi はスケルチで
     門番するが、metric に平滑化の時定数があるため、開くころには先頭の要素が
     終わっている (実測で C が R、A が T になった)。

  最初の作り直しがなぜ失敗したか (記録として残す)
  ----------------------------------------------------------------------------
  最初は「直近の窓の最小/最大だけを見る。時定数が無いから先頭が削れない」と
  考えた。これは間違いだった。窓の最大が **今の標本を含む** ので、立ち上がり
  の途中でも hi = 今の標本になり、閾値 lo + 0.6*(hi - lo) は必ず今の標本より
  下に来る。つまり **雑音より少し大きくなった瞬間に on** と判定してしまう。
  先頭の短点が長点として測られ、A が O、S が D、5 が 6 になった (13 例中 7 例
  が不一致。fldigi 由来の判定より悪い)。

  閾値の分母が「遅れて育つ推定量」でも「今の標本そのもの」でも駄目である。
  必要なのは **その要素の本当の頂点** で、それは要素が終わるまで分からない。

  どう考え直したか
  ----------------------------------------------------------------------------
  **判定を遅らせて、要素の前後を見てから決める。**

  長さ W の窓を持ち、窓の**中央**の標本について判定する。窓の後ろ半分
  (H = W/2) は中央より未来なので、要素の立ち上がりを判定する時点で、
  その要素の頂点はすでに窓の中にある。

      lo = 窓内の最小、 hi = 窓内の最大 (= 近傍の要素の頂点)
      閾値 = lo と hi の中点付近
      判定対象 = 窓の中央の標本

  立ち上がりでも立ち下がりでも同じ高さで交差するので、要素の長さが正しく
  測れる。これが先頭の短点を長点にしない理由である。

  判定は H 標本ぶん遅れるが、**すべての事象が同じだけ遅れる**ので、
  要素長の測定 (状態機械が使うのは時刻の差) には影響しない。増えるのは
  復号の待ち時間だけで、12 WPM なら 0.3 秒である。

  動き始めに待つのも H 標本でよい。窓全体 (W) が満ちるまで待つと、
  受信を始めた直後に信号が来る場合 (途中から同調した、前置きの無音が
  短い) に先頭の文字を落とす。待つ理由は「未来側が無い窓で判定しない」
  ことだけなので、未来側さえ揃えば過去側が短くても判定してよい。
  実測で 25 通り中 4 通り (前置き 0.2 秒以下) がこれで救われた。

  窓の長さについて
  ----------------------------------------------------------------------------
  窓は必ず「鳴っていない時間」を含んでいなければならない。含まなければ
  lo が上がって山が一つになり、長点の途中で判定できなくなる。
  符号の中で最も長く鳴り続けるのは長点 (3 単位) で、要素の間は 1 単位
  空く。中央を長点の真ん中に置いたとき、片側 3 単位あれば長点の残り 1.5
  単位に加えて 1 単位の間隔を必ず含む。よって H = 3 単位、W = 6 単位。

  「打鍵があるか」の門番 (2 つ)
  ----------------------------------------------------------------------------
  雑音しか無い区間で状態機械を動かさないために、窓が要素を含んでいるときだけ
  判定する。門番は 2 つで、目的が違う。

  (a) **二山になっているか** hi > lo * 6
      CW は on-off keying なので、要素を含む窓の大きさは必ず二山に分かれる。
      雑音だけの窓は分かれない。実測 (12 WPM / 8 kHz / この復調系):

          窓 6 単位のときの hi/lo の中央値
            雑音のみ         2.2
            信号あり     280 〜 12800

      これは **雑音だけの区間**を弾く。

      境目を 30 に置いていたが、これは誤りだった。上の実測は S/N の
      良い条件 (雑音 0.001 と 0.05) でしか取っておらず、比の下限は
      そのまま **S/N の下限**になる。信号と同程度の雑音 (0.6, 1.0) では
      比が 30 に届かず、門番が閉じたまま通信文を丸ごと落とした。
      端から端まで振ってみると 4〜10 がすべて合格で、3 以下では雑音が
      漏れる。中央を取って 6 とした。

      **境目を決めるときは、必ず両側から縛ること。** 弱い信号を通す
      試験だけなら緩めれば通り、雑音を止める試験だけなら厳しくすれば
      通る。両方を同時に課してはじめて位置が決まる
      (test_cw_leading の試験 6 と 7 がその対)。

  (b) **直近の頂点に対して十分大きいか** hi >= 直近の頂点 * 0.2
      雑音がほとんど無い入力では、送信が終わった後もフィルタの尾を引いた
      微小な残響が残る。残響は指数的に減衰するので hi/lo は大きくなり、
      (a) だけでは通ってしまう (実測で無雑音時に [I U T M I N T] という
      誤字列が出た)。そこで直近の頂点を保持し、その 2 割を下回る窓は
      要素なしとみなす。頂点は上には即座に追随し (先頭を削らないため)、
      下へは 20 単位で半減する程度にゆっくり落とす。
      これは **残響**を弾く。

  (a) は雑音を、(b) は残響を弾く。どちらか一方では足りない。
  どちらも比でしか判断しないので、入力の絶対的な大きさには依存しない。

  呼び出し側への要求: 入力は整定していること
  ----------------------------------------------------------------------------
  この検出器は「無音からトーンが始まった」を段差で見つける。したがって
  **段差なら何でも要素に見える**。受信系のフィルタが動き始めるときの
  立ち上がり (出力が 0 から本来の値へ単調に上がる過渡) も段差なので、
  そのまま渡すと先頭に余分な 1 要素が生まれる。

  実測: 過渡を渡したまま 25 通りの復号を 8 種で試すと 72/200 しか
  一致しない。過渡を捨てるだけで 200/200 になる。

  過渡の長さはフィルタの長さで決まるので、呼び出し側が数えて捨てる
  (CwModemImpl.WarmupCalls を参照)。検出器側からは長さが分からない。
  ============================================================================ }
unit CwToneDetect;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math;

type
  ECwToneDetectError = class(Exception);

  { 判定結果。「分からない」を持つのがこの型の要点である。
    呼び出し側は ctdUnknown のとき状態を変えてはならない。 }
  TCwToneDecision = (
    ctdUnknown,   // 打鍵が無い / まだ判断材料が足りない
    ctdOff,
    ctdOn
  );

const
  { 窓の半分の長さ [単位長]。長点の残り 1.5 単位 + 要素間 1 単位を含む長さ。 }
  CWTD_HALF_DOTS = 3;

  { (a) 打鍵ありとみなす hi/lo の下限。 }
  CWTD_KEYING_RATIO = 6.0;

  { (b) 直近の頂点に対して要求する最低の割合と、その頂点が半減するまでの
    長さ [単位長]。 }
  CWTD_PEAK_FRACTION = 0.2;
  CWTD_PEAK_HALFLIFE_DOTS = 20;

  { 閾値の位置 (lo と hi の間の割合)。中点にヒステリシスを上下 0.1 付ける。 }
  CWTD_ON_LEVEL  = 0.60;
  CWTD_OFF_LEVEL = 0.40;

type
  TCwToneDetector = class
  private
    { 窓は環状緩衝で保持する。最小/最大は単調両端キューで O(1) 償却。
      Feed の中では確保しない (X-04)。緩衝は Configure でのみ伸ばし、
      縮めないので、速度が上下しても確保は起きない。 }
    FDotCalls: Integer;             // 1 単位長 = Feed 何回分か
    FHalf: Integer;                 // H
    FWin: Integer;                  // W = 2H + 1
    FBuf: array of Double;          // FBuf[n mod FWin] = 絶対添字 n の大きさ
    FMaxQ, FMinQ: array of Int64;   // 単調両端キュー (絶対添字を持つ)
    FMaxH, FMaxT: Int64;            // FMaxQ の先頭/末尾 (単調増加する計数)
    FMinH, FMinT: Int64;
    FN: Int64;                      // 次に書き込む絶対添字

    FPeak: Double;                  // 直近の頂点 (門番 b)
    FPeakDecay: Double;             // 1 回あたりの減衰率

    FLast: TCwToneDecision;
    FLow, FHigh, FCentre: Double;
    FKeying: Boolean;

    procedure Push(AMagnitude: Double);
  public
    constructor Create;
    { ADotCalls: 1 単位長 (短点) が何回の Feed に相当するか。
      速度が変わったら呼び直す。受信中には呼ばないこと (窓を捨てるため)。 }
    procedure Configure(ADotCalls: Integer);
    procedure Reset;

    { 1 標本入れて、H 標本前の標本についての判定を返す。確保しない。 }
    function Feed(AMagnitude: Double): TCwToneDecision;

    { 入力が整定していない間 (フィルタの立ち上がり過渡) を渡してはならない。
      過渡の段差をトーンの始まりと取り違える。CwModemImpl.WarmupCalls 参照。 }

    { --- 診断用 (試験と障害調査のため) --- }
    property WindowLow: Double read FLow;
    property WindowHigh: Double read FHigh;
    { 判定対象になった標本 (窓の中央) の大きさ。 }
    property CentreValue: Double read FCentre;
    { 門番を両方通ったか = 窓が要素を含んでいるか。 }
    property IsKeying: Boolean read FKeying;
    property RecentPeak: Double read FPeak;
    { 判定が入力より何回ぶん遅れるか。 }
    property Latency: Integer read FHalf;
    property WindowLen: Integer read FWin;
    property DotCalls: Integer read FDotCalls;
    function OnThreshold: Double;
    function OffThreshold: Double;
    function Describe: string;
  end;

implementation

constructor TCwToneDetector.Create;
begin
  inherited Create;
  FDotCalls := 0;
  Configure(50);   { 12 WPM / 8 kHz / DEC_RATIO 16 のときの値 }
end;

procedure TCwToneDetector.Configure(ADotCalls: Integer);
begin
  if ADotCalls < 1 then
    ADotCalls := 1;
  FDotCalls := ADotCalls;
  FHalf := ADotCalls * CWTD_HALF_DOTS;
  FWin := 2 * FHalf + 1;

  { 伸ばすだけで縮めない。速度が上下しても再確保しない。 }
  if Length(FBuf) < FWin then
  begin
    SetLength(FBuf, FWin);
    SetLength(FMaxQ, FWin);
    SetLength(FMinQ, FWin);
  end;

  FPeakDecay := Exp(Ln(0.5) / (CWTD_PEAK_HALFLIFE_DOTS * ADotCalls));

  Reset;
end;

procedure TCwToneDetector.Reset;
begin
  FN := 0;
  FMaxH := 0; FMaxT := 0;
  FMinH := 0; FMinT := 0;
  FPeak := 0;
  FLast := ctdUnknown;
  FLow := 0;
  FHigh := 0;
  FCentre := 0;
  FKeying := False;
end;

procedure TCwToneDetector.Push(AMagnitude: Double);
var
  Oldest: Int64;
begin
  { 1. 最も古い枠を上書きする。 }
  FBuf[FN mod FWin] := AMagnitude;

  { 2. 窓から出た添字を先頭から捨てる。ここでは値を見ないので、
       上書き済みの枠を参照する危険がない。 }
  Oldest := FN - FWin;
  while (FMaxT > FMaxH) and (FMaxQ[FMaxH mod FWin] <= Oldest) do Inc(FMaxH);
  while (FMinT > FMinH) and (FMinQ[FMinH mod FWin] <= Oldest) do Inc(FMinH);

  { 3. 末尾から、新しい標本に負ける添字を捨てる。ここで参照する枠は
       すべて窓の中なので有効である。 }
  while (FMaxT > FMaxH) and
        (FBuf[FMaxQ[(FMaxT - 1) mod FWin] mod FWin] <= AMagnitude) do Dec(FMaxT);
  FMaxQ[FMaxT mod FWin] := FN;
  Inc(FMaxT);

  while (FMinT > FMinH) and
        (FBuf[FMinQ[(FMinT - 1) mod FWin] mod FWin] >= AMagnitude) do Dec(FMinT);
  FMinQ[FMinT mod FWin] := FN;
  Inc(FMinT);
end;

function TCwToneDetector.OnThreshold: Double;
begin
  Result := FLow + CWTD_ON_LEVEL * (FHigh - FLow);
end;

function TCwToneDetector.OffThreshold: Double;
begin
  Result := FLow + CWTD_OFF_LEVEL * (FHigh - FLow);
end;

function TCwToneDetector.Feed(AMagnitude: Double): TCwToneDecision;
begin
  if AMagnitude < 0 then
    AMagnitude := 0;

  Push(AMagnitude);

  { 「未来側」が揃うまでは判定しない。未来側の無い窓で判定することが、
    まさに先頭の要素を誤らせる状況だからである。逆に未来側さえ揃えば
    (過去側が短くても) 判定してよいので、待つのは窓の半分でよい。 }
  if FN < FHalf then
  begin
    Inc(FN);
    FLow := 0; FHigh := 0; FCentre := 0; FKeying := False;
    Exit(ctdUnknown);
  end;

  FHigh := FBuf[FMaxQ[FMaxH mod FWin] mod FWin];
  FLow  := FBuf[FMinQ[FMinH mod FWin] mod FWin];
  FCentre := FBuf[(FN - FHalf) mod FWin];

  { 直近の頂点。上には即座に、下へはゆっくり。 }
  if FHigh > FPeak then
    FPeak := FHigh
  else
    FPeak := FPeak * FPeakDecay;

  Inc(FN);

  { 門番 (a) 二山か / (b) 残響ではないか。 }
  FKeying := (FHigh > 0) and
             (FHigh > FLow * CWTD_KEYING_RATIO) and
             (FHigh >= FPeak * CWTD_PEAK_FRACTION);
  if not FKeying then
    Exit(ctdUnknown);   { FLast は保つ。窓が再び開いたとき続きから判定する。 }

  if FCentre > OnThreshold then
    FLast := ctdOn
  else if FCentre < OffThreshold then
    FLast := ctdOff;
  { どちらでもなければ前の判定を保つ (ヒステリシス)。 }

  Result := FLast;
end;

function TCwToneDetector.Describe: string;
var
  Ratio: Double;
begin
  if FLow > 0 then Ratio := FHigh / FLow else Ratio := 0;
  Result := Format('窓[%.6g, %.6g] 比=%.1f 中央=%.6g 頂点=%.6g 打鍵=%s ' +
    '閾値 on=%.6g off=%.6g',
    [FLow, FHigh, Ratio, FCentre, FPeak,
     BoolToStr(FKeying, 'あり', 'なし'),
     OnThreshold, OffThreshold]);
end;

end.
