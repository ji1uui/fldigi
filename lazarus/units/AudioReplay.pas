{ ============================================================================
  AudioReplay.pas

  Audio History Buffer の一区間を復調器に流し直す (Baseline v1.1 §4 X-06)。

  なぜ要るのか
  ----------------------------------------------------------------------------
  AudioRing.TAudioHistory は「直前の N 秒の音を保持する」ところまでを担う。
  だが要求 RT-005 は **Replay Decode を可能とする** ことまでを求めている。
  保持しているだけでは、その音をもう一度復号する手段が無い。

  流し直せると何ができるか:

  - **もう一度聞き直す** (§13.1)。運用者が呼出符号を取り逃したとき、
    その区間だけを設定を変えて復号し直す。生の受信は止めない。
  - **複数の戦略を同じ音に当てる** (Phase 3 / RTTY-021 Algorithm Portfolio)。
    同じ区間を別々の復調器に流し、Evidence を突き合わせる。
  - **障害を再現する** (Z-05)。誤った復号が出た区間を保存し、直したあとに
    同じ音を流して直ったことを確かめる。

  設計上の約束
  ----------------------------------------------------------------------------
  1. **稼働中の復調器に流し込んではならない。** 流し直しは呼び出し側が
     用意した別のインスタンスに対して行う。生の受信経路と状態を共有すると、
     聞き直しが実況を壊す。この単位では強制できないので、約束として書く。

  2. **Evidence には元の音声の位置が載る。** 流す前に復調器の
     StreamPosition に区間の先頭を入れるので、Evidence.SamplePos は
     履歴の座標のままになる。0 から数え直さない。これが無いと、
     聞き直した結果を元の音声に対応づけられない。

  3. **区間が無ければ、無いと言う。** 履歴は輪なので、古い区間は上書き
     される。上書きされた区間を「読めた」ことにして継ぎはぎの波形を
     渡すと、嘘の録音を復号することになる。TAudioHistory の破れ検出を
     区画ごとに使い、状態として返す。

  4. **区画の長さを生の受信と揃える。** 復調器は渡された長さの単位で
     内部状態を進めるので、長さが違うと同じ音でも結果が変わりうる。
     既定は ModemEngine.MODEM_BLOCK_SIZE と同じ値にしてある
     (test_replay がこの一致を試験している)。

  5. **並行して走らせてよい。** TAudioHistory の読み出しは読み手側の
     状態を変えないので、複数の TAudioReplay が同じ履歴を同時に読める。
     区画用の緩衝はインスタンスごとに持つ。Phase 3 の複数戦略同時実行を
     見越した形である。

  6. **止められる。** 長い区間の流し直しが停止要求を無視すると、
     終了できなくなる。区画ごとに進捗を通知し、False が返れば中断する。

  再現性について
  ----------------------------------------------------------------------------
  同じ区間を同じ設定で流せば、**インスタンスを使い回しても**同じ結果に
  なる。流す前に RxInit を呼ぶので、復調器は毎回同じ状態から始まる。

  ここは最初そうではなかった。RxInit がフィルタの遅延線や状態機械の
  時刻を消しておらず、同じ区間を 4 回流すと 1 回目と 2〜4 回目で復号が
  違った。前の音の尾が新しい音の頭に混ざっていたのである。Replay を
  作ったことで初めて見つかった欠陥で、RxInit を「受信系を初期状態に
  戻す」まで広げて直した (CwModemImpl.RxInit / RttyModemImpl.RxInit)。

  使い回せることは Phase 3 で効く。複数の戦略を同じ音に当てるとき、
  戦略の数だけ復調器を作り直すのでは高くつく。
  ============================================================================ }
unit AudioReplay;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Modem, DecodeEvidence, AudioRing;

const
  { 1 区画のサンプル数。**ModemEngine.MODEM_BLOCK_SIZE と同じ値にする。**
    生の受信と違う長さで流すと、同じ音でも復調器の内部状態の進み方が
    変わりうる。一致は test_replay が試験している。 }
  REPLAY_CHUNK_SAMPLES = 512;

type
  TReplayStatus = (
    rpsOk,            // 区間を最後まで流した
    rpsNotWritten,    // まだ書かれていない区間を求められた
    rpsOverwritten,   // 既に上書きされた区間 (聞き直すのが遅すぎた)
    rpsCancelled,     // 呼び出し側が中断した
    rpsBadRequest     // 引数が不正 / 履歴も復調器も無い
  );

  { 流し直しの結果。失敗したときに **何がどう駄目だったか** が
    分かるようにする。「失敗した」だけでは、運用者に何も言えない。 }
  TReplayResult = record
    Status: TReplayStatus;
    Message: string;        // 人が読む説明 (成功時は空)
    FromSample: Int64;      // 実際に流し始めた位置
    RequestedCount: Int64;  // 求められた長さ
    SamplesFed: Int64;      // 実際に流した長さ
    Chunks: Integer;        // 流した区画数
    Evidences: Integer;     // 流した結果として出た Evidence の件数
    function Ok: Boolean;
    function Describe: string;
  end;

  { 区画ごとに呼ばれる。False を返すと中断する。
    長い区間で UI を止めないため、また停止要求に応えるためにある。 }
  TReplayProgress = function(AFed, ATotal: Int64): Boolean of object;

  TAudioReplay = class
  private
    FChunk: array of Double;
    FChunkLen: Integer;
    FOnProgress: TReplayProgress;
    FBusy: Boolean;

    { Evidence を数えるために一時的に差し込む。呼び出し側の handler は
      失わずに後ろへ繋ぐ。 }
    FInnerDecode: TDecodeEvent;
    FEvidenceCount: Integer;
    procedure CountingDecode(Sender: TCustomModem;
      const AEvidence: TDecodeEvidence);
  public
    { AChunkSamples = 0 で REPLAY_CHUNK_SAMPLES。
      区画用の緩衝はここで一度だけ確保する。 }
    constructor Create(AChunkSamples: Integer = 0);

    { AHistory の [AFrom, AFrom+ACount) を AModem に流す。

      AModem は **稼働中でないもの**を渡すこと (冒頭の約束 1)。
      流す前に AModem.RxInit を呼び、StreamPosition に AFrom を入れる。 }
    function Run(AHistory: TAudioHistory; AModem: TCustomModem;
      AFrom, ACount: Int64): TReplayResult;

    { 直近 ASeconds 秒を流す。運用者の「さっきのをもう一度」がこれ。
      履歴に無い長さを求められたら、**あるだけ**を流す (それが最善の答で
      あって、断るのは親切ではない)。 }
    function RunLatest(AHistory: TAudioHistory; AModem: TCustomModem;
      ASeconds: Double): TReplayResult;

    property ChunkSamples: Integer read FChunkLen;
    property OnProgress: TReplayProgress read FOnProgress write FOnProgress;
    { 実行中は再入できない。1 インスタンスは 1 本の流し直しに使う。 }
    property Busy: Boolean read FBusy;
  end;

function ReplayStatusName(AStatus: TReplayStatus): string;

implementation

function ReplayStatusName(AStatus: TReplayStatus): string;
begin
  case AStatus of
    rpsOk:          Result := '成功';
    rpsNotWritten:  Result := '未記録';
    rpsOverwritten: Result := '上書き済';
    rpsCancelled:   Result := '中断';
    rpsBadRequest:  Result := '要求不正';
  else
    Result := '不明';
  end;
end;

{ 結果を空にする。

  FillChar を使ってはならない。TReplayResult は Message: string を持ち、
  関数結果の変数は呼び出し側の既存の変数が再利用されうる。FillChar は
  文字列の参照を参照計数を減らさずに 0 で潰すので、その文字列が漏れる。
  out 引数は入る時点でコンパイラが正しく解放するので、こちらを使う。 }
procedure InitReplayResult(out AResult: TReplayResult);
begin
  AResult.Status := rpsBadRequest;
  AResult.Message := '';
  AResult.FromSample := 0;
  AResult.RequestedCount := 0;
  AResult.SamplesFed := 0;
  AResult.Chunks := 0;
  AResult.Evidences := 0;
end;

{ TReplayResult }

function TReplayResult.Ok: Boolean;
begin
  Result := Status = rpsOk;
end;

function TReplayResult.Describe: string;
begin
  Result := Format('Replay %s: [%d, %d) のうち %d サンプル / %d 区画 / ' +
    'Evidence %d 件',
    [ReplayStatusName(Status), FromSample, FromSample + RequestedCount,
     SamplesFed, Chunks, Evidences]);
  if Message <> '' then
    Result := Result + ' — ' + Message;
end;

{ TAudioReplay }

constructor TAudioReplay.Create(AChunkSamples: Integer);
begin
  inherited Create;
  if AChunkSamples <= 0 then
    AChunkSamples := REPLAY_CHUNK_SAMPLES;
  FChunkLen := AChunkSamples;
  SetLength(FChunk, FChunkLen);
  FBusy := False;
end;

procedure TAudioReplay.CountingDecode(Sender: TCustomModem;
  const AEvidence: TDecodeEvidence);
begin
  Inc(FEvidenceCount);
  if Assigned(FInnerDecode) then
    FInnerDecode(Sender, AEvidence);
end;

function TAudioReplay.Run(AHistory: TAudioHistory; AModem: TCustomModem;
  AFrom, ACount: Int64): TReplayResult;
var
  first, last: Int64;
  pos, remaining: Int64;
  n: Integer;
  err: string;
begin
  InitReplayResult(Result);
  Result.FromSample := AFrom;
  Result.RequestedCount := ACount;

  if (AHistory = nil) or (AModem = nil) then
  begin
    Result.Status := rpsBadRequest;
    Result.Message := '履歴または復調器が指定されていません。';
    Exit;
  end;
  if FBusy then
  begin
    Result.Status := rpsBadRequest;
    Result.Message := 'この TAudioReplay は既に別の流し直しに使われています。';
    Exit;
  end;
  if ACount <= 0 then
  begin
    Result.Status := rpsBadRequest;
    Result.Message := '長さが 0 以下です。';
    Exit;
  end;
  if AFrom < 0 then
  begin
    Result.Status := rpsBadRequest;
    Result.Message := '開始位置が負です。';
    Exit;
  end;

  { 求められた区間が今も履歴にあるか。無いなら **どちら側に外れたか**を
    区別して返す。「上書きされた」と「まだ録れていない」は運用者にとって
    全く違う話で、前者は聞き直しが遅すぎ、後者は早すぎである。 }
  AHistory.LiveRange(first, last);
  if AFrom + ACount > last then
  begin
    Result.Status := rpsNotWritten;
    Result.Message := Format(
      'まだ録れていない区間です (要求末尾 %d / 記録済 %d)。',
      [AFrom + ACount, last]);
    Exit;
  end;
  if AFrom < first then
  begin
    Result.Status := rpsOverwritten;
    Result.Message := Format(
      '既に上書きされた区間です (要求開始 %d / 最古 %d)。' +
      '履歴を長くするか、聞き直しを早めてください。',
      [AFrom, first]);
    Exit;
  end;

  FBusy := True;
  FEvidenceCount := 0;
  FInnerDecode := AModem.OnDecode;
  AModem.OnDecode := @CountingDecode;
  try
    { 決まった状態から始める (再現性 Z-05)。位置は音声側の座標なので
      RxInit のあとに入れる。 }
    AModem.RxInit;
    AModem.StreamPosition := AFrom;

    pos := AFrom;
    remaining := ACount;
    while remaining > 0 do
    begin
      n := FChunkLen;
      if remaining < n then
        n := Integer(remaining);

      { 区画ごとに読み直す。長い区間を流している間に書き手が回り込んで
        追い越すことがあるので、まとめて読んでから流すのでは遅い。 }
      if not AHistory.TryReadRange(pos, n, FChunk, err) then
      begin
        Result.Status := rpsOverwritten;
        Result.Message := err;
        Exit;
      end;

      AModem.RxProcess(FChunk, n);

      Inc(pos, n);
      Dec(remaining, n);
      Inc(Result.Chunks);
      Result.SamplesFed := Result.SamplesFed + n;

      if Assigned(FOnProgress) then
        if not FOnProgress(Result.SamplesFed, ACount) then
        begin
          Result.Status := rpsCancelled;
          Result.Message := '呼び出し側が中断しました。';
          Exit;
        end;
    end;

    Result.Status := rpsOk;
  finally
    Result.Evidences := FEvidenceCount;
    AModem.OnDecode := FInnerDecode;
    FInnerDecode := nil;
    FBusy := False;
  end;
end;

function TAudioReplay.RunLatest(AHistory: TAudioHistory; AModem: TCustomModem;
  ASeconds: Double): TReplayResult;
var
  first, last, want, from_: Int64;
begin
  InitReplayResult(Result);
  if AHistory = nil then
  begin
    Result.Message := '履歴が指定されていません。';
    Exit;
  end;
  if ASeconds <= 0 then
  begin
    Result.Message := '長さが 0 以下です。';
    Exit;
  end;

  AHistory.LiveRange(first, last);
  want := Round(ASeconds * AHistory.SampleRate);
  from_ := last - want;
  { 求められた長さが履歴に無ければ、あるだけを流す。
    「10 秒欲しいが 6 秒しか無い」ときに断るのは答になっていない。 }
  if from_ < first then
    from_ := first;
  Result := Run(AHistory, AModem, from_, last - from_);
end;

end.
