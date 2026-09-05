{ ============================================================================
  WaterfallModel.pas

  Waterfall (滝表示) の **論理**。描画は含まない。
  Baseline v1.1 §12 Phase 2「Basic Waterfall」。

  なぜ描画と分けるのか
  ----------------------------------------------------------------------------
  units/ の下には LCL に依存するユニットが一つも無い。これは偶然ではなく、
  ModemUI.pas が「LCL の具象コンポーネントへの依存はこのユニットに持ち込まず、
  コールバック注入にとどめることで lcl-nogui 環境でも単体試験可能にする」と
  書いている方針そのものである。

  Waterfall は見た目の塊に見えるが、実際に間違いやすいのは描画ではなく
  **その手前**にある。

      どの bin をどの列に割り当てるか      -> 細い信号が消えるかどうか
      電力をどう段階値に落とすか            -> 見えるかどうか
      基準をどこに置くか                    -> 利得が変わっても見えるかどうか
      枠を取りこぼしたときどうするか        -> 表示が嘘をつくかどうか
      流し直し (Replay) のとき履歴をどうするか

  ここを LCL から切り離せば、全部を無画面で試験できる。
  描画側は「段階値の格子を色に置き換えて貼る」だけの薄い層になる。

  出すのは色ではなく段階値 (0..255)
  ----------------------------------------------------------------------------
  配色は使う側が決める。§10 の「色だけには依存しない」に従うなら、
  白黒や高コントラストの配色を選べる必要があり、そのためには
  **数値のまま**渡しておくのが正しい。列の dB もそのまま読めるので、
  カーソル位置の値を数字で出すこともできる。

  最大値で潰す (既定)
  ----------------------------------------------------------------------------
  1 列が何本もの bin をまたぐとき、平均を取ると **細い信号が消える**。
  8 kHz を 800 列で見ると 1 列 = 10 Hz = 約 10 bin。CW の搬送波は 1 bin
  なので、平均では 10 分の 1 (-10 dB) に薄まる。最大値なら残る。
  fldigi も既定は最大値で、平均は選択肢である (waterfall.cxx UPD_LOOP)。

  基準を自分で決める
  ----------------------------------------------------------------------------
  雑音の床はバンドの状況でも音声入力の利得でも動く。基準を固定すると、
  ある日は真っ黒、ある日は真っ白になり、**信号を見つけるという滝の仕事**が
  果たせない。そこで列 dB の中央値を追う。信号は少数派なので、中央値は
  信号ではなく雑音を指す (ModemDSP.PercentileInPlace)。

  ただしこれは **表示の正規化**であって、較正された雑音推定ではない。
  Phase 3 の Noise Estimator (SPC-002) が入ったら、その共有推定値を
  wrManual + SetManualFloor で差し込めばよい。API を足す必要はない。

  分かっている性質: 入力が完全な無音 (digital silence) だと、列の dB は
  すべて PowerToDb の下限 -200 dB になり、床もそこまで落ちる。そこへ
  わずかでも信号が入ると、窓の裾まで表示範囲の上端を超えて飽和する。
  「何も無いところに比べれば桁違いに大きい」という意味では正しいが、
  太い塊に見える。実際の受信には必ず雑音の床があるので起きない。
  下限を設けて防ぐこともできるが、根拠のある値が無いので置いていない
  —— 適当な閾値を入れるより、性質を書いておくほうがよい。

  スレッド
  ----------------------------------------------------------------------------
  このクラスは **一つのスレッドから使う**。Pump を二つのスレッドから
  同時に呼んではならない。読む側 (SpectrumService) は書き手が別スレッドでも
  安全なので、音声スレッドが Feed し、UI スレッドが Pump する形になる。
  ============================================================================ }
unit WaterfallModel;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Math, ModemDSP, SpectrumService;

const
  { 列数の既定。fldigi の表示幅と同程度。 }
  WF_DEFAULT_COLUMNS = 800;
  { 保持する行数の既定。既定の枠 (0.256 秒) で約 65 秒ぶん。 }
  WF_DEFAULT_ROWS = 256;
  { 表示する dB の幅。fldigi の ampspan と同じ。 }
  WF_DEFAULT_RANGE_DB = 75.0;
  { 雑音の床を表示範囲の下端からどれだけ上に置くか。
    0 にすると雑音が黒に潰れて「無音」と見分けられない。 }
  WF_DEFAULT_FLOOR_MARGIN_DB = 6.0;
  { 自動基準の追従率 (1 行あたり)。1.0 で即座、0 で動かない。
    速すぎると信号が通るたびに画面全体が明滅する。 }
  WF_DEFAULT_ADAPT_RATE = 0.10;
  { 雑音の床とみなす順位。0.5 = 中央値。 }
  WF_DEFAULT_FLOOR_PERCENTILE = 0.5;

type
  EWaterfallError = class(Exception);

  { 1 列が複数の bin にまたがるときの潰し方。 }
  TWaterfallBinMerge = (
    wmMax,    // 既定。細い信号を残す
    wmMean    // 平らにする。雑音は落ち着くが細い線は消える
  );

  { 表示範囲の下端を誰が決めるか。 }
  TWaterfallReference = (
    wrAuto,   // 既定。列 dB の順位統計を追う
    wrManual  // 使う側が決める (Phase 3 の共有雑音推定を差し込む口)
  );

  { Pump が何をしたか。黙って捨てず、必ず言う。 }
  TWaterfallPumpResult = record
    Rows: Integer;             // 追加した行数
    DroppedFrames: Int64;      // 表示が追いつかず捨てた枠
    StreamRestarted: Boolean;  // 流し直された。履歴を捨てた
    function Describe: string;
  end;

  TWaterfallModel = class
  private
    FService: TSpectrumService;
    FColumns: Integer;
    FRows: Integer;

    { 表示する周波数の範囲。 }
    FSpanLoHz: Double;
    FSpanHiHz: Double;

    { 列 c は bin [FColBin[c], FColBin[c+1]) を覆う。要素数は FColumns+1。
      境界を共有するので、隙間も重なりも生じない。
      拡大しすぎて範囲が空になる列のために、最も近い 1 本を別に持つ。
      どちらも Pump のたびに割り算をしないための表である (X-04)。 }
    FColBin: array of Integer;
    FColNearest: array of Integer;

    { 段階値の格子。FGrid[row * FColumns + col]。row は物理位置。 }
    FGrid: array of Byte;
    FHead: Integer;            // 最新行の物理位置
    FRowsFilled: Integer;

    FBins: array of Double;    // SpectrumService からの受け皿
    FLastDb: array of Double;  // 最新行の列 dB (カーソル表示と自動基準に使う)
    FScratch: array of Double; // 順位統計の作業用 (並べ替えるので控えが要る)

    FMerge: TWaterfallBinMerge;
    FRefMode: TWaterfallReference;
    FFloorDb: Double;
    FHasFloor: Boolean;
    FRangeDb: Double;
    FFloorMarginDb: Double;
    FAdaptRate: Double;
    FFloorPercentile: Double;

    FReader: TSpectrumReader;
    FTotalRows: Int64;
    FTotalDropped: Int64;

    procedure BuildColumnMap;
    procedure AppendRow;
    function QuantiseDb(ADb: Double): Byte;
    procedure SetRangeDb(AValue: Double);
    procedure SetAdaptRate(AValue: Double);
    procedure SetFloorPercentile(AValue: Double);
    procedure SetFloorMarginDb(AValue: Double);
  public
    constructor Create(AService: TSpectrumService;
      AColumns: Integer = WF_DEFAULT_COLUMNS;
      ARows: Integer = WF_DEFAULT_ROWS);

    { 表示する周波数の範囲を変える。
      **履歴は捨てる** —— 残すと、古い行が古い割り当てのまま表示され、
      同じ列が行によって別の周波数を指すことになる。 }
    procedure SetSpan(ALoHz, AHiHz: Double);

    { 溜まっている枠をすべて取り込む。確保しない (X-04)。 }
    function Pump: TWaterfallPumpResult;

    { 履歴を捨てる。次の行で基準を取り直す。 }
    procedure Clear;

    { ARow = 0 が最新行。まだ無い行は 0 を返す。 }
    function Level(ARow, AColumn: Integer): Byte;
    { 1 行ぶんをまとめて取り出す (描画用)。ADest は Columns 個以上。 }
    procedure CopyRow(ARow: Integer; var ADest: array of Byte);

    { 最新行の、その列の dB。カーソル位置の値を数字で出すのに使う。 }
    function ColumnDb(AColumn: Integer): Double;
    { 列の中心周波数 [Hz]。 }
    function ColumnFrequency(AColumn: Integer): Double;
    { 周波数に対応する列。範囲外は端に丸める (クリック追尾に使う)。 }
    function FrequencyToColumn(AHz: Double): Integer;
    { 1 列の幅 [Hz]。 }
    function ColumnWidthHz: Double;

    { 表示範囲の下端を自分で決める。wrManual に切り替わる。 }
    procedure SetManualFloor(AFloorDb: Double);

    property Columns: Integer read FColumns;
    property Rows: Integer read FRows;
    property RowsFilled: Integer read FRowsFilled;
    property SpanLoHz: Double read FSpanLoHz;
    property SpanHiHz: Double read FSpanHiHz;
    property BinMerge: TWaterfallBinMerge read FMerge write FMerge;
    property ReferenceMode: TWaterfallReference read FRefMode write FRefMode;
    { 表示範囲。FloorDb が段階値 0、FloorDb + RangeDb が 255。

      これらを変えても **履歴は捨てない**。捨てるのは列の意味 (どの周波数を
      指すか) が変わるときだけである。明るさの設定を変えても、過去の行が
      どの周波数の話だったかは変わらない。生きた表示なのだから、
      過去は過去の見え方のまま残ってよい (fldigi も同じ)。 }
    property FloorDb: Double read FFloorDb;
    property RangeDb: Double read FRangeDb write SetRangeDb;
    property FloorMarginDb: Double read FFloorMarginDb write SetFloorMarginDb;
    property AdaptRate: Double read FAdaptRate write SetAdaptRate;
    property FloorPercentile: Double read FFloorPercentile write SetFloorPercentile;

    { これまでに作った行数と、表示が追いつかず捨てた枠の総数。
      捨てた数は「表示が遅れている」ことの唯一の手掛かりなので残す。 }
    function TotalRows: Int64;
    function TotalDroppedFrames: Int64;
  end;

implementation

function TWaterfallPumpResult.Describe: string;
begin
  Result := Format('%d 行', [Rows]);
  if DroppedFrames > 0 then
    Result := Result + Format(' / %d 枠を捨てた', [DroppedFrames]);
  if StreamRestarted then
    Result := Result + ' / 流し直しのため履歴を捨てた';
end;

{ TWaterfallModel }

constructor TWaterfallModel.Create(AService: TSpectrumService;
  AColumns, ARows: Integer);
begin
  inherited Create;
  if AService = nil then
    raise EWaterfallError.Create('スペクトルサービスが渡されていません。');
  if AColumns < 1 then
    raise EWaterfallError.CreateFmt('列数は 1 以上です (指定 %d)', [AColumns]);
  if ARows < 1 then
    raise EWaterfallError.CreateFmt('行数は 1 以上です (指定 %d)', [ARows]);

  FService := AService;
  FColumns := AColumns;
  FRows := ARows;

  FMerge := wmMax;
  FRefMode := wrAuto;
  FRangeDb := WF_DEFAULT_RANGE_DB;
  FFloorMarginDb := WF_DEFAULT_FLOOR_MARGIN_DB;
  FAdaptRate := WF_DEFAULT_ADAPT_RATE;
  FFloorPercentile := WF_DEFAULT_FLOOR_PERCENTILE;

  SetLength(FGrid, Int64(FRows) * FColumns);
  SetLength(FBins, FService.BinCount);
  SetLength(FLastDb, FColumns);
  SetLength(FScratch, FColumns);
  SetLength(FColBin, FColumns + 1);
  SetLength(FColNearest, FColumns);

  { 既定は音声帯域の全部。ナイキストまで見せる。 }
  FSpanLoHz := 0;
  FSpanHiHz := FService.SampleRate / 2;
  BuildColumnMap;

  FReader := FService.NewReader;
  Clear;
end;

procedure TWaterfallModel.BuildColumnMap;

  function BinAt(AHz: Double; AMaxBin: Integer): Integer;
  begin
    Result := Round(AHz / FService.BinWidthHz);
    if Result < 0 then Result := 0;
    if Result > AMaxBin then Result := AMaxBin;
  end;

var
  c, maxBin: Integer;
  width: Double;
begin
  { 列の境界を bin 番号に直して置く。境界は隣の列と共有するので、
    どの bin もちょうど一つの列に属する (重なると wmMean の勘定が狂い、
    隙間ができると信号が消える)。

    最上端の bin (ナイキスト) は、範囲の上端がちょうどそこに来るため
    どの列にも入らない。0.98 Hz 幅の 1 本で、しかも折り返し防止フィルタの
    肩にあたる位置なので、実信号は無い。承知のうえで落としている。 }
  maxBin := FService.BinCount - 1;
  width := (FSpanHiHz - FSpanLoHz) / FColumns;
  for c := 0 to FColumns do
    FColBin[c] := BinAt(FSpanLoHz + width * c, maxBin);

  { 拡大して 1 列が 1 bin より細くなると、境界が同じ値になって範囲が空になる。
    そのときは **列の中心に最も近い 1 本**を使う。

    ここで「必ず 1 本ずつ前へ進める」ようにしてはならない。一見それらしく
    動くが、列と周波数の対応が静かにずれる。1000..1100 Hz を 800 列で見ると
    ColumnFrequency は 1050 Hz と言いながら 1500 Hz あたりの bin を映す —— 
    **表示が嘘をつく**。拡大の意味は「同じ bin が横に伸びて見える」ことである。 }
  for c := 0 to FColumns - 1 do
    FColNearest[c] := BinAt(FSpanLoHz + width * (c + 0.5), maxBin);
end;

procedure TWaterfallModel.SetSpan(ALoHz, AHiHz: Double);
var
  nyquist: Double;
begin
  nyquist := FService.SampleRate / 2;
  if AHiHz <= ALoHz then
    raise EWaterfallError.CreateFmt(
      '上端は下端より大きくなければなりません (%.1f..%.1f Hz)', [ALoHz, AHiHz]);
  if (ALoHz < 0) or (AHiHz > nyquist) then
    raise EWaterfallError.CreateFmt(
      '表示範囲は 0..%.1f Hz の内側です (指定 %.1f..%.1f Hz)',
      [nyquist, ALoHz, AHiHz]);
  FSpanLoHz := ALoHz;
  FSpanHiHz := AHiHz;
  BuildColumnMap;
  { 古い行は古い割り当てのまま。残せば同じ列が行ごとに別の周波数を指す。 }
  Clear;
end;

procedure TWaterfallModel.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FGrid) do
    FGrid[i] := 0;
  for i := 0 to FColumns - 1 do
    FLastDb[i] := PowerToDb(0);
  FRowsFilled := 0;
  { 次の AppendRow で 0 に回るように、末尾に置いておく。 }
  FHead := FRows - 1;
  { 基準は取り直す。流し直しの直後に前の録音の基準から 20 行かけて
    寄っていくより、新しい音に合わせて一息で決めたほうがよい。 }
  FHasFloor := False;
end;

function TWaterfallModel.QuantiseDb(ADb: Double): Byte;
var
  v: Double;
begin
  { FFloorDb を 0、FFloorDb + FRangeDb を 255 に写す。外は端に潰す。 }
  v := 255.0 * (ADb - FFloorDb) / FRangeDb;
  if v <= 0 then Exit(0);
  if v >= 255 then Exit(255);
  Result := Byte(Round(v));
end;

procedure TWaterfallModel.AppendRow;
var
  c, b, b0, b1, n: Integer;
  acc, p, newFloor: Double;
  base: Int64;
begin
  { --- 1. 列ごとに bin を潰して dB にする --- }
  for c := 0 to FColumns - 1 do
  begin
    b0 := FColBin[c];
    b1 := FColBin[c + 1];
    if b1 <= b0 then
    begin
      { 列が bin より細い (拡大しすぎ)。中心に最も近い 1 本を映す。 }
      b0 := FColNearest[c];
      b1 := b0 + 1;
    end;
    if b1 > FService.BinCount then b1 := FService.BinCount;

    if FMerge = wmMax then
    begin
      acc := 0;
      for b := b0 to b1 - 1 do
      begin
        p := FBins[b];
        if p > acc then acc := p;
      end;
    end
    else
    begin
      { 平均は **線形パワーで**取る。dB の平均は幾何平均であって
        電力の平均ではない。 }
      acc := 0;
      n := b1 - b0;
      for b := b0 to b1 - 1 do
        acc := acc + FBins[b];
      if n > 0 then acc := acc / n;
    end;
    FLastDb[c] := PowerToDb(acc);
  end;

  { --- 2. 表示範囲の下端を決める --- }
  if FRefMode = wrAuto then
  begin
    Move(FLastDb[0], FScratch[0], FColumns * SizeOf(Double));
    { 中央値は信号ではなく雑音を指す。信号は少数派だからである。 }
    newFloor := PercentileInPlace(FScratch, FColumns, FFloorPercentile)
                - FFloorMarginDb;
    if not FHasFloor then
    begin
      FFloorDb := newFloor;
      FHasFloor := True;
    end
    else
      FFloorDb := FFloorDb + FAdaptRate * (newFloor - FFloorDb);
  end;

  { --- 3. 行を書く --- }
  FHead := (FHead + 1) mod FRows;
  base := Int64(FHead) * FColumns;
  for c := 0 to FColumns - 1 do
    FGrid[base + c] := QuantiseDb(FLastDb[c]);

  if FRowsFilled < FRows then Inc(FRowsFilled);
  Inc(FTotalRows);
end;

function TWaterfallModel.Pump: TWaterfallPumpResult;
var
  info: TSpectrumFrameInfo;
  r: TSpectrumReadResult;
begin
  Result.Rows := 0;
  Result.DroppedFrames := 0;
  Result.StreamRestarted := False;
  repeat
    r := FService.TryRead(FReader, FBins, info);
    case r of
      srOk:
        begin
          AppendRow;
          Inc(Result.Rows);
        end;
      srMissed:
        begin
          { 滝は取りこぼしてよい —— 表示が飛ぶだけである。
            だが **何枠飛んだかは残す**。表示が遅れていることに
            気づく手掛かりが他に無い。 }
          Result.DroppedFrames := Result.DroppedFrames + info.MissedFrames;
          FTotalDropped := FTotalDropped + info.MissedFrames;
        end;
      srReset:
        begin
          { 流し直された (X-06 Replay)。前の録音の絵を下に残したまま
            新しい録音を描き足すと、一つの連続した受信に見えてしまう。 }
          Clear;
          Result.Rows := 0;
          Result.StreamRestarted := True;
        end;
      srNoData: ;
    end;
  until r = srNoData;
end;

{ 索引の扱いを二つに分けている。

    行/列が保持範囲の外       -> 呼ぶ側の誤り。例外にする
    行はあるが、まだ埋まっていない -> 起動直後の正常な状態。0 を返す

  「まだ描かれていない行」は表示の側にとって普通の状態なので、例外にすると
  起動のたびに握り潰しの try が要る。一方 Rows を超える索引は誤りであって、
  黙って 0 を返すと描画のずれが静かに残る。 }
function TWaterfallModel.Level(ARow, AColumn: Integer): Byte;
var
  phys: Integer;
begin
  if (ARow < 0) or (ARow >= FRows) then
    raise EWaterfallError.CreateFmt(
      '行が範囲外です (%d / 0..%d)', [ARow, FRows - 1]);
  if (AColumn < 0) or (AColumn >= FColumns) then
    raise EWaterfallError.CreateFmt(
      '列が範囲外です (%d / 0..%d)', [AColumn, FColumns - 1]);
  if ARow >= FRowsFilled then Exit(0);
  phys := (FHead - ARow + FRows) mod FRows;
  Result := FGrid[Int64(phys) * FColumns + AColumn];
end;

procedure TWaterfallModel.CopyRow(ARow: Integer; var ADest: array of Byte);
var
  phys: Integer;
begin
  if (ARow < 0) or (ARow >= FRows) then
    raise EWaterfallError.CreateFmt(
      '行が範囲外です (%d / 0..%d)', [ARow, FRows - 1]);
  if Length(ADest) < FColumns then
    raise EWaterfallError.CreateFmt(
      '受け皿が足りません (要求 %d / 受け皿 %d)', [FColumns, Length(ADest)]);
  if ARow >= FRowsFilled then
  begin
    FillChar(ADest[0], FColumns, 0);
    Exit;
  end;
  phys := (FHead - ARow + FRows) mod FRows;
  Move(FGrid[Int64(phys) * FColumns], ADest[0], FColumns);
end;

procedure TWaterfallModel.SetRangeDb(AValue: Double);
begin
  { 0 以下だと段階値の計算が 0 除算になる。黙って壊れるより断る。 }
  if AValue <= 0 then
    raise EWaterfallError.CreateFmt(
      '表示範囲の幅は正の値です (指定 %.3f dB)', [AValue]);
  FRangeDb := AValue;
end;

procedure TWaterfallModel.SetAdaptRate(AValue: Double);
begin
  { 1 を超えると行き過ぎて振動する。負だと基準が信号から遠ざかる。 }
  if (AValue < 0) or (AValue > 1) then
    raise EWaterfallError.CreateFmt(
      '追従率は 0..1 です (指定 %.3f)', [AValue]);
  FAdaptRate := AValue;
end;

procedure TWaterfallModel.SetFloorPercentile(AValue: Double);
begin
  if (AValue < 0) or (AValue > 1) then
    raise EWaterfallError.CreateFmt(
      '順位は 0..1 です (指定 %.3f)', [AValue]);
  FFloorPercentile := AValue;
end;

procedure TWaterfallModel.SetFloorMarginDb(AValue: Double);
begin
  { 表示範囲より大きな余裕を取ると、雑音が上端に張り付いて真っ白になる。 }
  if (AValue < 0) or (AValue >= FRangeDb) then
    raise EWaterfallError.CreateFmt(
      '余裕は 0 以上・表示範囲 %.1f dB 未満です (指定 %.1f dB)',
      [FRangeDb, AValue]);
  FFloorMarginDb := AValue;
end;

function TWaterfallModel.ColumnDb(AColumn: Integer): Double;
begin
  if (AColumn < 0) or (AColumn >= FColumns) then
    raise EWaterfallError.CreateFmt(
      '列が範囲外です (%d / 0..%d)', [AColumn, FColumns - 1]);
  Result := FLastDb[AColumn];
end;

function TWaterfallModel.ColumnWidthHz: Double;
begin
  Result := (FSpanHiHz - FSpanLoHz) / FColumns;
end;

function TWaterfallModel.ColumnFrequency(AColumn: Integer): Double;
begin
  { 列の **中心**。左端を返すと、クリック追尾が半列ぶん低くずれる。 }
  Result := FSpanLoHz + (AColumn + 0.5) * ColumnWidthHz;
end;

function TWaterfallModel.FrequencyToColumn(AHz: Double): Integer;
begin
  Result := Trunc((AHz - FSpanLoHz) / ColumnWidthHz);
  if Result < 0 then Result := 0;
  if Result > FColumns - 1 then Result := FColumns - 1;
end;

procedure TWaterfallModel.SetManualFloor(AFloorDb: Double);
begin
  FRefMode := wrManual;
  FFloorDb := AFloorDb;
  FHasFloor := True;
end;

function TWaterfallModel.TotalRows: Int64;
begin
  Result := FTotalRows;
end;

function TWaterfallModel.TotalDroppedFrames: Int64;
begin
  Result := FTotalDropped;
end;

end.
