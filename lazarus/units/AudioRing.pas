{ ============================================================================
  AudioRing.pas

  Architecture & Requirements Baseline v1.1 Phase 1 (Modern Runtime) の
  Ring Buffer と History Buffer。

  Phase 1 の完了条件はこう書かれている。

      長時間受信で dropout がなく、コア数に応じて処理がスケールし、
      Replay 履歴を保持できること。

  このうち前者 (dropout) と後者 (Replay 履歴) がこのユニットの担当である。

  いまの音声経路の何が問題か
  ----------------------------------------------------------------------------
  現状 TModemEngine.RxLoopStep は

      ReadSamples() でブロックして読む → その場で RxProcess() で復調

  という同期経路になっている。つまり **復調が遅れた分だけ次の読み出しが
  遅れる**。復調が 1 ブロック分の時間を超えた瞬間に取りこぼしが始まり、
  しかもどこで落ちたのか分からない。

  取り込みと復調をリングで分ければ、復調が一時的に遅れても取り込みは
  進み続ける。それでも間に合わなければ落ちるが、**落ちたことが数として
  残る** (ADR-010)。「たぶん大丈夫」ではなく「何件落ちた」と言える。

  なぜ二つの型に分けたのか
  ----------------------------------------------------------------------------
  溢れたときの正しい振る舞いが逆だからである。

  | 型            | 用途            | 溢れたら              |
  |---------------|-----------------|-----------------------|
  | TAudioRing    | 取り込み→復調   | 新しい方を捨てる      |
  | TAudioHistory | Replay 履歴     | 古い方を上書きする    |

  リングは「連続した流れ」を渡す道なので、途中を上書きすると読み手が
  今どこを読んでいるのか分からなくなる。だから新しい方を捨てて、
  切れ目を 1 か所に閉じ込める。

  履歴は「直近 N 秒」という窓なので、古い方を捨てるのが定義そのもの。

  一つの型に方針を引数で持たせることもできるが、そうすると呼び出し側が
  取り違えても気づけない。型が違えば取り違えようがない。

  Replay 履歴は後段フェーズの前提である
  ----------------------------------------------------------------------------
  Phase 3 の RTTY-021「QSB 時に複数復調戦略を比較」は、**同じ音声を
  複数の復調器に流す** ことを要求している。生の音声は一度きりしか
  流れてこないので、履歴が無ければ比較のしようがない。

  また PluginApi の pcReplay (supports_replay) は §11.1 が挙げている
  capability だが、HOST_CAPABILITIES にまだ入っていない。Core が
  提供していないものを提供すると書かないためである。このユニットが
  その裏付けになる。

  realtime 経路の制約 (X-04 / ADR-009)
  ----------------------------------------------------------------------------
  書き込み側は音声スレッドから呼ばれる。したがって:

    - 確保しない。容量は生成時に決め、以後伸ばさない。
    - 待たない。ロックを取らない。相手がどんな状態でも即座に戻る。
    - 割らない。容量を 2 の冪にして、剰余ではなくビットマスクで回す。

  単一生産者・単一消費者に限定しているのも同じ理由である。取り込みは
  1 本、復調も 1 本と要求から決まっている (ADR-009: 並行性は要求から
  導く)。多対多にすると CAS ループが要り、realtime 側で待ちが発生しうる。
  ============================================================================ }
unit AudioRing;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils;

type
  EAudioRingError = class(Exception);

  { --- 取り込み → 復調 のリング (単一生産者・単一消費者) ---

    書き手は音声スレッド、読み手は復調スレッドの 1 本ずつに限る。
    どちらもロックを取らず、待たない。 }
  TAudioRing = class
  private
    FBuf: array of Double;
    FCapacity: Integer;      // 2 の冪
    FMask: Integer;          // FCapacity - 1
    { 書き手だけが進める。読み手は読むだけ。 }
    FWritePos: Int64;
    { 読み手だけが進める。書き手は読むだけ。
      別のキャッシュラインへ追い出すために間を空ける (false sharing 回避)。 }
    FPad: array[0..7] of Int64;
    FReadPos: Int64;
    FOverrunSamples: Int64;  // 書けずに捨てたサンプル数
    FOverrunEvents: Int64;   // 捨てが起きた回数
  public
    { ACapacity は 2 の冪へ切り上げる。生成時に確保し、以後伸ばさない。 }
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;

    { --- 書き手 ---
      入るだけ書いて、書けた数を返す。待たない。**捨てたとは数えない**。
      呼び出し側が空きを待って再試行できる場面 (ファイル再生、試験) 用。 }
    function Write(const ABuf: array of Double; ACount: Integer): Integer;

    { --- 書き手 (音声スレッド用) ---
      入るだけ書き、入らなかった分は **捨てて数える**。
      音声コールバックは待てないので、こちらを使う。

      二つに分けたのは、満杯を「捨てた」と数えてよいかが呼び出し側に
      よって違うからである。再試行する側の書き込みまで捨てたと数えると、
      取りこぼし件数が「復調が追いついていない量」を表さなくなり、
      ADR-010 の記録が診断に使えなくなる。 }
    function WriteOrDrop(const ABuf: array of Double; ACount: Integer): Integer;

    { --- 読み手 (復調スレッド) ---
      あるだけ読む。戻り値: 実際に読めたサンプル数。 }
    function Read(var ABuf: array of Double; ACount: Integer): Integer;

    { 読まずに捨てる (状態を切り替えるときなど)。戻り値: 捨てた数。 }
    function Discard(ACount: Integer): Integer;
    { 全部捨てる。書き手が動いている間に呼ぶと競合するので、
      停止中にのみ使うこと。 }
    procedure Clear;

    function Available: Integer;   // 読める数
    function FreeSpace: Integer;   // 書ける数
    function Capacity: Integer;
    function IsEmpty: Boolean;
    function IsFull: Boolean;

    { 取りこぼしの記録 (ADR-010)。0 でなければ復調が追いついていない。 }
    property OverrunSamples: Int64 read FOverrunSamples;
    property OverrunEvents: Int64 read FOverrunEvents;
    procedure ResetCounters;
    function Describe: string;
  end;

  { --- Replay 履歴 ---

    直近 N サンプルを保持し、古いものから上書きする。
    書き手は音声スレッド (待たない・確保しない)。
    読み手は任意のスレッドで、**過去の任意の区間** を要求できる。

    区間の指定に「先頭からの通算サンプル番号」を使うのが要点である。
    リング内の位置で指定すると、書き手が回った瞬間に意味が変わる。
    通算番号なら、要求した区間がまだ生きているかを判定できる。 }
  TAudioHistory = class
  private
    FBuf: array of Double;
    FCapacity: Integer;
    FMask: Integer;
    { --- 通算サンプル数を二つ持つ理由 ---

      書き手は「データを書いてから位置を公開する」順で動く。すると
      公開前のわずかな間、**スロットは既に上書きされているのに
      読み手には古い位置が見えている**。読み手がその隙に生存区間の
      下端を読むと、いちばん古いはずの場所からいちばん新しい値が
      返ってくる。実際にこれが起きた (試験 6b が検出した)。

      そこで書き手は書き込む前に「ここまで潰す」と予約し、書き終えて
      から「ここまで読める」と確定する。

        FReserved  : これから潰す範囲まで含む。**上書き判定に使う**
        FCommitted : 書き終えた範囲まで。**読める範囲の判定に使う**

      FReserved >= FCommitted なので、読み手が使える窓
      [FReserved - 容量, FCommitted) は両端とも安全側に狭い。
      窓は「容量 - 書き込み中のブロック長」ぶんになる。 }
    FReserved: Int64;
    FCommitted: Int64;
    FSampleRate: Integer;
  public
    constructor Create(ACapacity: Integer; ASampleRate: Integer = 8000);
    destructor Destroy; override;

    { 秒数から容量を決める版。 }
    class function ForSeconds(ASeconds: Double;
      ASampleRate: Integer): TAudioHistory;

    { --- 書き手 (音声スレッド) ---
      常に全部書ける (古いものを上書きするため)。待たない。 }
    procedure Append(const ABuf: array of Double; ACount: Integer);

    { --- 読み手 ---
      通算サンプル番号 AFrom から ACount サンプルを取り出す。

      戻り値 False の意味は 2 つある。AError で区別する:
        - 要求区間が既に上書きされている / まだ書かれていない
        - 読んでいる最中に書き手が追いついて上書きした (読み取りが破れた)

      後者を検出できることが重要である。検出しないと、前半が新しく
      後半が古い、という継ぎはぎの波形を「録音」として渡してしまう。
      Phase 3 が復調戦略を比較するとき、その波形は嘘の材料になる。 }
    function TryReadRange(AFrom: Int64; ACount: Integer;
      var ABuf: array of Double; out AError: string): Boolean;

    { 直近 ACount サンプル。戻り値: 実際に取れた数 (0 なら失敗)。 }
    function ReadLatest(ACount: Integer; var ABuf: array of Double): Integer;

    { いま生きている区間 [AFirst, ALast)。 }
    procedure LiveRange(out AFirst, ALast: Int64);

    function TotalWritten: Int64;
    function Capacity: Integer;
    function AvailableSamples: Integer;   // 保持しているサンプル数
    function DurationSeconds: Double;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    function Describe: string;
  end;

{ 2 の冪へ切り上げる。 }
function NextPowerOfTwo(AValue: Integer): Integer;

implementation

const
  MIN_CAPACITY = 16;
  { 2 の冪でこれ以上は現実的でない (Double で 1GiB 超)。 }
  MAX_CAPACITY = 1 shl 27;

function NextPowerOfTwo(AValue: Integer): Integer;
begin
  if AValue <= MIN_CAPACITY then Exit(MIN_CAPACITY);
  Result := MIN_CAPACITY;
  while (Result < AValue) and (Result < MAX_CAPACITY) do
    Result := Result shl 1;
end;

{ ============================ TAudioRing ============================ }

constructor TAudioRing.Create(ACapacity: Integer);
begin
  inherited Create;
  if ACapacity <= 0 then
    raise EAudioRingError.Create('リングの容量は 1 以上でなければなりません');
  if ACapacity > MAX_CAPACITY then
    raise EAudioRingError.CreateFmt(
      'リングの容量が大きすぎます (要求 %d / 上限 %d)',
      [ACapacity, MAX_CAPACITY]);
  FCapacity := NextPowerOfTwo(ACapacity);
  FMask := FCapacity - 1;
  { ここが唯一の確保。以後 realtime 経路では一切確保しない (X-04)。 }
  SetLength(FBuf, FCapacity);
  FWritePos := 0;
  FReadPos := 0;
  FOverrunSamples := 0;
  FOverrunEvents := 0;
  FillChar(FPad, SizeOf(FPad), 0);
end;

destructor TAudioRing.Destroy;
begin
  SetLength(FBuf, 0);
  inherited Destroy;
end;

function TAudioRing.Available: Integer;
var
  w, r: Int64;
begin
  { 書き手が進めた分だけ読める。読み手から見て w は増える一方なので、
    古い値を読んでも「少なめに見える」だけで安全側に外れる。 }
  w := FWritePos;
  ReadBarrier;
  r := FReadPos;
  Result := Integer(w - r);
end;

function TAudioRing.FreeSpace: Integer;
begin
  Result := FCapacity - Available;
end;

function TAudioRing.Capacity: Integer;
begin
  Result := FCapacity;
end;

function TAudioRing.IsEmpty: Boolean;
begin
  Result := Available = 0;
end;

function TAudioRing.IsFull: Boolean;
begin
  Result := Available >= FCapacity;
end;

function TAudioRing.Write(const ABuf: array of Double;
  ACount: Integer): Integer;
var
  space, n, i, idx: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  if ACount > Length(ABuf) then
    ACount := Length(ABuf);

  space := FreeSpace;
  if space <= 0 then Exit(0);

  n := ACount;
  if n > space then
    { 入る分だけ書く。**古い方を上書きしない** ── 読み手が読んでいる
      途中の連続性を壊さないため。 }
    n := space;

  idx := Integer(FWritePos and FMask);
  for i := 0 to n - 1 do
  begin
    FBuf[idx] := ABuf[i];
    idx := (idx + 1) and FMask;
  end;

  { データを書き終えてから位置を公開する。逆順だと、読み手が
    まだ書かれていない領域を読みうる。 }
  WriteBarrier;
  FWritePos := FWritePos + n;
  Result := n;
end;

function TAudioRing.WriteOrDrop(const ABuf: array of Double;
  ACount: Integer): Integer;
var
  dropped: Integer;
begin
  if ACount <= 0 then Exit(0);
  if ACount > Length(ABuf) then
    ACount := Length(ABuf);

  Result := Write(ABuf, ACount);

  dropped := ACount - Result;
  if dropped > 0 then
  begin
    { 復調が追いついていない。捨てるしかないが、黙って捨てない。 }
    Inc(FOverrunSamples, dropped);
    Inc(FOverrunEvents);
  end;
end;

function TAudioRing.Read(var ABuf: array of Double;
  ACount: Integer): Integer;
var
  avail, n, i, idx: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  if ACount > Length(ABuf) then
    ACount := Length(ABuf);

  avail := Available;
  if avail <= 0 then Exit;

  n := ACount;
  if n > avail then n := avail;

  { Available が ReadBarrier を含むので、ここで読むデータは
    書き手が公開済みのものだけである。 }
  idx := Integer(FReadPos and FMask);
  for i := 0 to n - 1 do
  begin
    ABuf[i] := FBuf[idx];
    idx := (idx + 1) and FMask;
  end;

  { 読み終えてから位置を公開する。逆順だと、書き手がまだ読んでいない
    領域を上書きしうる。 }
  WriteBarrier;
  FReadPos := FReadPos + n;
  Result := n;
end;

function TAudioRing.Discard(ACount: Integer): Integer;
var
  avail, n: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  avail := Available;
  if avail <= 0 then Exit;
  n := ACount;
  if n > avail then n := avail;
  WriteBarrier;
  FReadPos := FReadPos + n;
  Result := n;
end;

procedure TAudioRing.Clear;
begin
  { 書き手が動いている間に呼ぶと競合する。停止中にのみ使うこと。 }
  FReadPos := FWritePos;
end;

procedure TAudioRing.ResetCounters;
begin
  FOverrunSamples := 0;
  FOverrunEvents := 0;
end;

function TAudioRing.Describe: string;
begin
  Result := Format('リング 容量%d / 保持%d / 空き%d / 取りこぼし %d サンプル (%d 回)',
    [FCapacity, Available, FreeSpace, FOverrunSamples, FOverrunEvents]);
end;

{ ============================ TAudioHistory ============================ }

constructor TAudioHistory.Create(ACapacity: Integer; ASampleRate: Integer);
begin
  inherited Create;
  if ACapacity <= 0 then
    raise EAudioRingError.Create('履歴の容量は 1 以上でなければなりません');
  if ACapacity > MAX_CAPACITY then
    raise EAudioRingError.CreateFmt(
      '履歴の容量が大きすぎます (要求 %d / 上限 %d)',
      [ACapacity, MAX_CAPACITY]);
  FCapacity := NextPowerOfTwo(ACapacity);
  FMask := FCapacity - 1;
  SetLength(FBuf, FCapacity);
  FReserved := 0;
  FCommitted := 0;
  if ASampleRate <= 0 then ASampleRate := 8000;
  FSampleRate := ASampleRate;
end;

destructor TAudioHistory.Destroy;
begin
  SetLength(FBuf, 0);
  inherited Destroy;
end;

class function TAudioHistory.ForSeconds(ASeconds: Double;
  ASampleRate: Integer): TAudioHistory;
var
  n: Int64;
begin
  if ASampleRate <= 0 then ASampleRate := 8000;
  if ASeconds <= 0 then ASeconds := 1;
  n := Round(ASeconds * ASampleRate);
  if n > MAX_CAPACITY then n := MAX_CAPACITY;
  Result := TAudioHistory.Create(Integer(n), ASampleRate);
end;

procedure TAudioHistory.Append(const ABuf: array of Double; ACount: Integer);
var
  i, idx, start: Integer;
begin
  if ACount <= 0 then Exit;
  if ACount > Length(ABuf) then
    ACount := Length(ABuf);

  { 容量より長い入力は、末尾の容量分だけ残せばよい
    (それ以前はどのみち上書きされる)。 }
  start := 0;
  if ACount > FCapacity then
  begin
    start := ACount - FCapacity;
    ACount := FCapacity;
  end;

  { --- 予約 ---
    書き込む前に「ここまで潰す」と宣言する。読み手はこれを見て
    上書きされうる範囲を保守的に見積もる。書いてから宣言すると、
    その隙に読み手が潰れた場所を「まだ生きている」と誤認する。 }
  { 容量超で読み飛ばした分 (start) は書き出し位置にも効く。
    ここを FCommitted だけで取ると、飛ばした分だけ書き出し位置がずれる。 }
  idx := Integer((FCommitted + start) and FMask);
  FReserved := FReserved + start + ACount;
  WriteBarrier;

  for i := start to start + ACount - 1 do
  begin
    FBuf[idx] := ABuf[i];
    idx := (idx + 1) and FMask;
  end;

  { --- 確定 ---
    書き終えてから「ここまで読める」を公開する。
    飛ばした分 (start) も通算に数える。数えないと通算番号がずれ、
    読み手の区間指定が意味を失う。 }
  WriteBarrier;
  FCommitted := FCommitted + start + ACount;
end;

function TAudioHistory.TotalWritten: Int64;
begin
  { 読める範囲の末尾。書き込み中のぶんは含めない。 }
  Result := FCommitted;
  ReadBarrier;
end;

function TAudioHistory.Capacity: Integer;
begin
  Result := FCapacity;
end;

function TAudioHistory.AvailableSamples: Integer;
var
  first, last: Int64;
begin
  { 実際に取り出せる長さ。書き込み中のブロックのぶん、容量より狭くなる。 }
  LiveRange(first, last);
  if last <= first then
    Result := 0
  else if last - first > FCapacity then
    Result := FCapacity
  else
    Result := Integer(last - first);
end;

function TAudioHistory.DurationSeconds: Double;
begin
  if FSampleRate <= 0 then Exit(0);
  Result := AvailableSamples / FSampleRate;
end;

procedure TAudioHistory.LiveRange(out AFirst, ALast: Int64);
var
  r: Int64;
begin
  ALast := TotalWritten;          { 読める末尾は確定済みまで }
  r := FReserved;
  ReadBarrier;
  AFirst := r - FCapacity;        { 下端は予約で見る (保守的に狭く) }
  if AFirst < 0 then AFirst := 0;
end;

function TAudioHistory.TryReadRange(AFrom: Int64; ACount: Integer;
  var ABuf: array of Double; out AError: string): Boolean;
var
  before, after, resv: Int64;
  i, idx: Integer;
begin
  AError := '';
  Result := False;

  if ACount <= 0 then
  begin
    AError := '取り出す長さが 0 以下です。';
    Exit;
  end;
  if ACount > Length(ABuf) then
  begin
    AError := Format('受け皿が足りません (要求 %d / 受け皿 %d)。',
      [ACount, Length(ABuf)]);
    Exit;
  end;
  if ACount > FCapacity then
  begin
    AError := Format('履歴より長い区間は取り出せません (要求 %d / 容量 %d)。',
      [ACount, FCapacity]);
    Exit;
  end;
  if AFrom < 0 then
  begin
    AError := '開始位置が負です。';
    Exit;
  end;

  before := TotalWritten;          { 確定済み = 読める末尾 }

  if AFrom + ACount > before then
  begin
    AError := Format('まだ書かれていない区間です (要求末尾 %d / 書込済 %d)。',
      [AFrom + ACount, before]);
    Exit;
  end;

  { 上書きの判定は予約で行う。確定で判定すると、書き込み中のブロックが
    既に潰した場所を「生きている」と誤認する。 }
  resv := FReserved;
  ReadBarrier;
  if AFrom < resv - FCapacity then
  begin
    AError := Format('既に上書きされた区間です (要求開始 %d / 最古 %d)。',
      [AFrom, resv - FCapacity]);
    Exit;
  end;

  idx := Integer(AFrom and FMask);
  for i := 0 to ACount - 1 do
  begin
    ABuf[i] := FBuf[idx];
    idx := (idx + 1) and FMask;
  end;

  { --- 読み取りが破れていないかの確認 ---
    複写している間に書き手が回り込み、要求区間の先頭を上書きして
    いれば、いま手元にあるのは前半が古く後半が新しい継ぎはぎである。
    そのまま返すと「録音」として嘘の波形を渡すことになる。 }
  ReadBarrier;
  after := FReserved;
  if AFrom < after - FCapacity then
  begin
    AError := Format(
      '読み取り中に上書きされました (開始 %d / 読了時の最古 %d)。' +
      '履歴を長くするか、取り出しを早めてください。',
      [AFrom, after - FCapacity]);
    Exit;
  end;

  Result := True;
end;

function TAudioHistory.ReadLatest(ACount: Integer;
  var ABuf: array of Double): Integer;
var
  t: Int64;
  err: string;
  n: Integer;
begin
  Result := 0;
  if ACount <= 0 then Exit;
  n := ACount;
  if n > FCapacity then n := FCapacity;

  t := TotalWritten;
  if t < n then n := Integer(t);
  if n <= 0 then Exit;

  if TryReadRange(t - n, n, ABuf, err) then
    Result := n;
end;

function TAudioHistory.Describe: string;
var
  f, l: Int64;
begin
  LiveRange(f, l);
  Result := Format('履歴 容量%d (%.1f秒) / 保持%d / 生存区間 [%d, %d)',
    [FCapacity, FCapacity / FSampleRate, AvailableSamples, f, l]);
end;

end.
