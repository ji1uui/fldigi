{ ============================================================================
  test_eventbus.lpr

  ADR-001 (Data Plane / Control Plane 境界) と §12 Event Bus の検証。

  重点:
    - 購読者の例外でバス全体が止まらないこと (§12 / B-04 / Z-06)
    - 有界であること。溢れても伸び続けず、捨てた件数が分かること
    - 種別で絞り込めること (疎結合)
    - 発行が確保を伴わないこと (X-04 との整合。数値イベントの場合)
    - 破棄が走行中の発行と競合しても壊れないこと

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_eventbus;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, SyncObjs, EventBus;

var
  FailCount: Integer = 0;
  TestCount: Integer = 0;

procedure Check(ACondition: Boolean; const AMsg: string);
begin
  Inc(TestCount);
  if ACondition then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    Inc(FailCount);
  end;
end;

type
  { 受け取ったイベントを記録する購読者。 }
  TRecorder = class
  private
    FKinds: TStringList;
    FInts: TStringList;
    FTexts: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const AEvent: TBusEvent);
    property Kinds: TStringList read FKinds;
    property Ints: TStringList read FInts;
    property Texts: TStringList read FTexts;
  end;

  { 必ず例外を投げる購読者。 }
  TThrower = class
  private
    FCalls: Integer;
  public
    procedure Handle(const AEvent: TBusEvent);
    property Calls: Integer read FCalls;
  end;

  { バスへ発行し返す購読者 (再入の確認)。 }
  TReentrant = class
  private
    FBus: TEventBus;
    FCalls: Integer;
  public
    constructor Create(ABus: TEventBus);
    procedure Handle(const AEvent: TBusEvent);
    property Calls: Integer read FCalls;
  end;

constructor TRecorder.Create;
begin
  inherited Create;
  FKinds := TStringList.Create;
  FInts := TStringList.Create;
  FTexts := TStringList.Create;
end;

destructor TRecorder.Destroy;
begin
  FKinds.Free; FInts.Free; FTexts.Free;
  inherited Destroy;
end;

procedure TRecorder.Handle(const AEvent: TBusEvent);
begin
  FKinds.Add(BusEventKindToStr(AEvent.Kind));
  FInts.Add(IntToStr(AEvent.I1));
  FTexts.Add(AEvent.Text);
end;

procedure TThrower.Handle(const AEvent: TBusEvent);
begin
  Inc(FCalls);
  raise Exception.Create('購読者の障害を模擬');
end;

constructor TReentrant.Create(ABus: TEventBus);
begin
  inherited Create;
  FBus := ABus;
end;

procedure TReentrant.Handle(const AEvent: TBusEvent);
begin
  Inc(FCalls);
  { 1 回だけ発行し返す (無限ループにしない) }
  if AEvent.Kind = bekQsoStarted then
    FBus.PublishNumeric(bekLogUpdated, AEvent.I1);
end;

{ --------------------------------------------------------------------- }

procedure TestBasicPubSub;
var
  bus: TEventBus;
  r: TRecorder;
  n: Integer;
begin
  WriteLn;
  WriteLn('--- 1. 発行と購読 ---');
  bus := TEventBus.Create;
  r := TRecorder.Create;
  try
    bus.AutoDispatch := False;   { テストでは手で配送する }
    bus.Subscribe(@r.Handle);
    Check(bus.SubscriberCount = 1, '購読者が登録される');

    bus.PublishNumeric(bekDecodedSymbol, Ord('A'), 0, 0.8, 12.5, 'RTTY');
    bus.PublishText(bekStatusText, '受信開始', 'engine');
    Check(bus.PendingCount = 2, '配送前は溜まっている');
    Check(r.Kinds.Count = 0, '配送するまで購読者は呼ばれない');

    n := bus.DispatchPending;
    Check(n = 2, '2 件配送された');
    Check(bus.PendingCount = 0, '配送後は空');
    Check(r.Kinds.Count = 2, '購読者が 2 件受け取った');
    Check(r.Kinds[0] = 'DecodedSymbol', '1件目の種別');
    Check(r.Ints[0] = IntToStr(Ord('A')), '数値スロットが届く');
    Check(r.Texts[1] = '受信開始', '文字列スロットが届く');

    { 発行順が保たれること }
    r.Kinds.Clear; r.Ints.Clear; r.Texts.Clear;
    for n := 1 to 50 do
      bus.PublishNumeric(bekDecodedSymbol, n);
    bus.DispatchPending;
    Check(r.Ints.Count = 50, '50 件すべて届く');
    Check((r.Ints[0] = '1') and (r.Ints[49] = '50'), '発行順が保たれる');

    Check(bus.PublishedCount = 52, '発行件数が数えられている');
    Check(bus.DeliveredCount = 52, '配送件数が数えられている');
    Check(bus.DroppedCount = 0, '取りこぼしなし');
  finally
    r.Free;
    bus.Free;
  end;
end;

procedure TestKindFiltering;
var
  bus: TEventBus;
  all, only: TRecorder;
begin
  WriteLn;
  WriteLn('--- 2. 種別による絞り込み ---');
  bus := TEventBus.Create;
  all := TRecorder.Create;
  only := TRecorder.Create;
  try
    bus.AutoDispatch := False;
    bus.Subscribe(@all.Handle);                        { 空集合 = 全部 }
    bus.Subscribe(@only.Handle, [bekQsoCompleted, bekLogUpdated]);

    bus.PublishNumeric(bekDecodedSymbol, 1);
    bus.PublishNumeric(bekQsoCompleted, 2);
    bus.PublishNumeric(bekRigChanged, 3);
    bus.PublishNumeric(bekLogUpdated, 4);
    bus.DispatchPending;

    Check(all.Kinds.Count = 4, '全部購読は 4 件受け取る');
    Check(only.Kinds.Count = 2, '絞り込みは 2 件だけ受け取る');
    Check(only.Ints[0] = '2', '絞り込んだ 1 件目');
    Check(only.Ints[1] = '4', '絞り込んだ 2 件目');

    bus.Unsubscribe(@only.Handle);
    Check(bus.SubscriberCount = 1, '購読解除できる');
    bus.PublishNumeric(bekLogUpdated, 5);
    bus.DispatchPending;
    Check(only.Kinds.Count = 2, '解除後は届かない');
  finally
    only.Free; all.Free; bus.Free;
  end;
end;

procedure TestSubscriberExceptionIsContained;
{ §12「Subscriber 例外によって Event Bus 全体を停止させない」。
  1 つの購読者が投げた例外で他の購読者への配送が止まると、
  障害が波及する (B-04 / Z-06)。 }
var
  bus: TEventBus;
  before, thrower, after: TRecorder;
  bad: TThrower;
begin
  WriteLn;
  WriteLn('--- 3. 購読者の例外を封じ込める ---');
  bus := TEventBus.Create;
  before := TRecorder.Create;
  after := TRecorder.Create;
  thrower := nil;
  bad := TThrower.Create;
  try
    bus.AutoDispatch := False;
    bus.Subscribe(@before.Handle);
    bus.Subscribe(@bad.Handle);      { ここで必ず例外 }
    bus.Subscribe(@after.Handle);

    bus.PublishNumeric(bekDecodedSymbol, 1);
    bus.PublishNumeric(bekDecodedSymbol, 2);
    bus.DispatchPending;

    Check(before.Kinds.Count = 2, '例外を投げる購読者の前は届く');
    Check(bad.Calls = 2, '例外を投げる購読者も呼ばれる');
    Check(after.Kinds.Count = 2,
      '例外を投げる購読者の後ろにも届く (配送が止まらない)');
    Check(bus.SubscriberErrorCount = 2, '購読者の例外件数が数えられている');
    Check(bus.DeliveredCount = 2, '例外があっても配送済みとして数える');
  finally
    bad.Free; after.Free; before.Free; bus.Free;
    if thrower <> nil then thrower.Free;
  end;
end;

procedure TestBounded;
{ 有界であること。UI が詰まってもメモリが伸び続けない。 }
var
  bus: TEventBus;
  r: TRecorder;
  i: Integer;
begin
  WriteLn;
  WriteLn('--- 4. 有界であること ---');
  bus := TEventBus.Create(16);   { 小さい容量で試す }
  r := TRecorder.Create;
  try
    bus.AutoDispatch := False;
    bus.Subscribe(@r.Handle);

    for i := 1 to 100 do
      bus.PublishNumeric(bekDecodedSymbol, i);

    Check(bus.PendingCount = 16, '容量を超えて溜まらない (実際: ' +
      IntToStr(bus.PendingCount) + ')');
    Check(bus.DroppedCount = 84, '捨てた件数が分かる (実際: ' +
      IntToStr(bus.DroppedCount) + ')');

    bus.DispatchPending;
    Check(r.Ints.Count = 16, '残っていた 16 件が届く');
    Check(r.Ints[0] = '85', '古いものから捨てられ、新しい方が残る');
    Check(r.Ints[15] = '100', '最新が残る');
  finally
    r.Free; bus.Free;
  end;
end;

procedure TestReentrantPublish;
{ 購読者がバスへ発行し返しても壊れないこと (デッドロックしない)。 }
var
  bus: TEventBus;
  re: TReentrant;
  r: TRecorder;
begin
  WriteLn;
  WriteLn('--- 5. 購読者からの再発行 ---');
  bus := TEventBus.Create;
  re := TReentrant.Create(bus);
  r := TRecorder.Create;
  try
    bus.AutoDispatch := False;
    bus.Subscribe(@re.Handle);
    bus.Subscribe(@r.Handle);

    bus.PublishNumeric(bekQsoStarted, 7);
    bus.DispatchPending;

    Check(re.Calls >= 1, '購読者が呼ばれた');
    Check(r.Kinds.IndexOf('QSOStarted') >= 0, '元のイベントが届く');
    Check(r.Kinds.IndexOf('LogUpdated') >= 0,
      '購読者から発行し直したイベントも同じ配送で届く');
  finally
    r.Free; re.Free; bus.Free;
  end;
end;

type
  TPublisherThread = class(TThread)
  private
    FBus: TEventBus;
    FCount: Integer;
    FDone: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ABus: TEventBus; ACount: Integer);
    property Done: Boolean read FDone;
  end;

constructor TPublisherThread.Create(ABus: TEventBus; ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBus := ABus;
  FCount := ACount;
end;

procedure TPublisherThread.Execute;
var
  i: Integer;
begin
  for i := 1 to FCount do
    FBus.PublishNumeric(bekDecodedSymbol, i);
  FDone := True;
end;

procedure TestConcurrentPublishAndDestroy;
{ 発行スレッドを走らせながら生成・破棄を繰り返す。 }
const
  ROUNDS = 50;
var
  i, spin: Integer;
  bus: TEventBus;
  pub: TPublisherThread;
begin
  WriteLn;
  WriteLn('--- 6. 発行中の破棄 ---');
  for i := 1 to ROUNDS do
  begin
    bus := TEventBus.Create(64);
    bus.AutoDispatch := False;
    pub := TPublisherThread.Create(bus, 200);
    pub.Start;
    spin := 0;
    while (not pub.Done) and (spin < 500) do
    begin
      Sleep(1);
      Inc(spin);
    end;
    bus.Free;
    pub.Free;
  end;
  Check(True, IntToStr(ROUNDS) + ' 回の「発行スレッド走行中の生成・破棄」が完了する');
end;

procedure TestControlPlaneOnly;
{ ADR-001: Data Plane のデータを載せられない構造になっていること。
  イベントが固定長レコードであることを大きさで確認する。
  動的配列やストリームのフィールドを足すと SizeOf が変わるので、
  意図しない拡張に気づける。 }
var
  ev: TBusEvent;
begin
  WriteLn;
  WriteLn('--- 7. Control Plane 専用であること ---');
  WriteLn('  SizeOf(TBusEvent) = ', SizeOf(TBusEvent), ' バイト');
  { 数値 4 本 + 文字列 2 本 + 日時 + 種別。ポインタ 2 本ぶんを含めても
    100 バイト程度に収まる。波形を載せられる大きさではない。 }
  Check(SizeOf(TBusEvent) < 128,
    'イベントが固定長の小さなレコードである (波形は載せられない)');

  ev.Kind := bekDecodedSymbol;
  ev.I1 := Ord('E');
  ev.I2 := 1;
  ev.D1 := 0.42;
  ev.D2 := 9.5;
  ev.Text := '';
  ev.Source := 'RTTY';
  ev.TimestampUtc := 0;
  Check(Pos('DecodedSymbol', ev.Describe) > 0, '診断表示に種別が出る');
  Check(Pos('RTTY', ev.Describe) > 0, '診断表示に発行元が出る');
end;

begin
  WriteLn('=== ADR-001 / §12 Event Bus テスト ===');

  TestBasicPubSub;
  TestKindFiltering;
  TestSubscriberExceptionIsContained;
  TestBounded;
  TestReentrantPublish;
  TestConcurrentPublishAndDestroy;
  TestControlPlaneOnly;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  if FailCount > 0 then
    Halt(1);
end.
