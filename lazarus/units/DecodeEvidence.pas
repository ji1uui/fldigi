{ ============================================================================
  DecodeEvidence.pas

  Architecture & Requirements Baseline v1.1 の ADR-002
  「Modem API は複数候補・Evidence・Confidence を将来返せる型にする」
  に対応する Core interface。Phase 0 の成果物である。

  なぜこの型が要るのか:
  ----------------------------------------------------------------------------
  従来の復調器は「確定した1文字」を1つずつ上位へ push していた。

      procedure PutRxChar(ACh: Integer);

  この形は原理的に次を運べない。

    - 第2候補 (「E かもしれないし I かもしれない」)
    - その判断の根拠 (軟判定の余裕、尤度、相関)
    - どの復調戦略が出したのか (Phase 3 の Algorithm Portfolio)
    - 入力のどの位置から出たのか (Phase 3 以降の Replay / 再現)

  Phase 4 の Context Assistance と Confidence-aware GUI は、まさにこれらを
  必要とする。復調器を増やしてから型を変えると全モデムの書き換えになるため、
  Phase 0 のうちに確定させる。

  Evidence と Confidence を区別する (§7 CF-01):
  ----------------------------------------------------------------------------
  本ユニットが運ぶのは **Evidence** であって Confidence ではない。

    Evidence   : 復調器の内部尺度。軟判定の余裕、尤度、相関値など。
                 モードごとに意味も尺度も違い、校正されていない。
    Confidence : ユーザーに見せる校正済みの確からしさ。
                 P(correct | c) ≈ c が成り立つように校正したもの (§17.1)。

  この2つを混同すると「Confidence 90%」と表示しながら実際の正答率が
  60% という、不確実性を誤解させる表示になる。変換 (校正) は Phase 4 の
  責務であり、本ユニットは生の Evidence を素直に運ぶことに徹する。

  MetricKind を型に持たせているのは、尺度の意味がモードごとに違うためである。
  「大きいほど良い」という向きだけを共通の約束とし、値そのものの比較は
  同じ MetricKind どうしでのみ意味を持つ。
  ============================================================================ }
unit DecodeEvidence;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

const
  { 候補が無いことを表す文字コード。 }
  DECODE_NO_CHAR = -1;

type
  { 復調器が出す内部尺度の種類。
    値の意味がモードごとに違うため、値と一緒に種類も運ぶ。 }
  TEvidenceMetricKind = (
    emkNone,           // 尺度なし (確定文字のみ。旧 PutRxChar 相当)
    emkSoftMargin,     // -1..+1 に正規化した軟判定の余裕 (0 が判定境界)
    emkLogLikelihood,  // 対数尤度 (大きいほど確からしい)
    emkCorrelation     // 相関値 (大きいほど確からしい)
  );

  { 復調候補 1 件。 }
  TDecodeCandidate = record
    Ch: Integer;      // 文字コード
    Metric: Double;   // MetricKind に応じた尺度。大きいほど確からしい
  end;
  TDecodeCandidateArray = array of TDecodeCandidate;

  { 1 回の復調結果とその根拠。
    復調器から上位へ渡される唯一の単位である。 }
  TDecodeEvidence = record
    { 候補。[0] が最有力。長さ 0 は「候補なし」を意味する。 }
    Candidates: TDecodeCandidateArray;
    MetricKind: TEvidenceMetricKind;

    { どの復調戦略が出したか。Phase 3 の Algorithm Portfolio で
      複数戦略を並列評価する際に、出所を識別するために使う。 }
    DecoderName: string;

    { この結果を生んだ入力の位置 (Open からの通算サンプル数)。
      Phase 3 以降の Replay Decode (X-06) と障害再現に使う。
      不明な場合は -1。 }
    SamplePos: Int64;

    { 受信状態 (§6.1)。復調器が持っているものだけ埋める。 }
    HasSnr: Boolean;
    SnrDb: Double;
    HasFreqOffset: Boolean;
    FreqOffsetHz: Double;

    { 最有力候補の文字コード。候補が無ければ DECODE_NO_CHAR。 }
    function BestChar: Integer;
    { 最有力候補の尺度。候補が無ければ 0。 }
    function BestMetric: Double;
    function CandidateCount: Integer;
    { 第2候補以降があるか (Phase 4 の補正候補提示に使う)。 }
    function HasAlternatives: Boolean;
    { 診断・ログ用の1行表現 (Z-01 Observability)。 }
    function Describe: string;
  end;

{ 候補 1 件だけ・尺度なしの Evidence を作る。
  軟判定を持たない復調器 (従来の確定文字出力) 用。 }
function SingleCandidateEvidence(ACh: Integer;
  const ADecoderName: string = ''): TDecodeEvidence;

{ 候補 1 件 + 尺度つきの Evidence を作る。 }
function ScoredCandidateEvidence(ACh: Integer; AMetric: Double;
  AKind: TEvidenceMetricKind; const ADecoderName: string = ''): TDecodeEvidence;

{ Evidence に候補を追加する (尺度の降順に挿入する)。 }
procedure AddCandidate(var AEvidence: TDecodeEvidence;
  ACh: Integer; AMetric: Double);

function EvidenceMetricKindToStr(AKind: TEvidenceMetricKind): string;

implementation

function TDecodeEvidence.CandidateCount: Integer;
begin
  Result := Length(Candidates);
end;

function TDecodeEvidence.BestChar: Integer;
begin
  if Length(Candidates) = 0 then
    Result := DECODE_NO_CHAR
  else
    Result := Candidates[0].Ch;
end;

function TDecodeEvidence.BestMetric: Double;
begin
  if Length(Candidates) = 0 then
    Result := 0
  else
    Result := Candidates[0].Metric;
end;

function TDecodeEvidence.HasAlternatives: Boolean;
begin
  Result := Length(Candidates) > 1;
end;

function TDecodeEvidence.Describe: string;
var
  i: Integer;
  ch: Integer;
  s: string;
begin
  if Length(Candidates) = 0 then
    Exit('(候補なし)');
  Result := '';
  for i := 0 to High(Candidates) do
  begin
    ch := Candidates[i].Ch;
    if (ch >= 32) and (ch < 127) then
      s := '''' + Chr(ch) + ''''
    else
      s := '#' + IntToStr(ch);
    if MetricKind <> emkNone then
      s := s + Format('(%.3f)', [Candidates[i].Metric]);
    if Result <> '' then
      Result := Result + ' | ';
    Result := Result + s;
  end;
  if DecoderName <> '' then
    Result := Result + ' [' + DecoderName + ']';
  if HasSnr then
    Result := Result + Format(' SNR=%.1fdB', [SnrDb]);
end;

function SingleCandidateEvidence(ACh: Integer;
  const ADecoderName: string): TDecodeEvidence;
begin
  Result.Candidates := nil;
  SetLength(Result.Candidates, 1);
  Result.Candidates[0].Ch := ACh;
  Result.Candidates[0].Metric := 0;
  Result.MetricKind := emkNone;
  Result.DecoderName := ADecoderName;
  Result.SamplePos := -1;
  Result.HasSnr := False;
  Result.SnrDb := 0;
  Result.HasFreqOffset := False;
  Result.FreqOffsetHz := 0;
end;

function ScoredCandidateEvidence(ACh: Integer; AMetric: Double;
  AKind: TEvidenceMetricKind; const ADecoderName: string): TDecodeEvidence;
begin
  Result := SingleCandidateEvidence(ACh, ADecoderName);
  Result.Candidates[0].Metric := AMetric;
  Result.MetricKind := AKind;
end;

procedure AddCandidate(var AEvidence: TDecodeEvidence;
  ACh: Integer; AMetric: Double);
var
  n, i, pos: Integer;
begin
  n := Length(AEvidence.Candidates);
  pos := n;
  for i := 0 to n - 1 do
    if AMetric > AEvidence.Candidates[i].Metric then
    begin
      pos := i;
      Break;
    end;
  SetLength(AEvidence.Candidates, n + 1);
  for i := n downto pos + 1 do
    AEvidence.Candidates[i] := AEvidence.Candidates[i - 1];
  AEvidence.Candidates[pos].Ch := ACh;
  AEvidence.Candidates[pos].Metric := AMetric;
end;

function EvidenceMetricKindToStr(AKind: TEvidenceMetricKind): string;
begin
  case AKind of
    emkSoftMargin:    Result := 'soft-margin';
    emkLogLikelihood: Result := 'log-likelihood';
    emkCorrelation:   Result := 'correlation';
  else
    Result := 'none';
  end;
end;

end.
