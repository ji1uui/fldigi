{ ============================================================================
  MacroEngine.pas

  fldigi の src/misc/macros.cxx (class MACROTEXT, MACRO_EDIT の <TAG> 展開)
  を Lazarus/FPC 向けに再設計した「マクロ展開エンジン」。

  何のための機能か:
  ----------------------------------------------------------------------------
  アマチュア無線のデジタルモード運用では、交信の大半が定型文で進む。
  CQ を出す → 呼ばれる → レポートを送る → 相手のレポートを受ける →
  名前とQTHを送る → 73 で終わる。この定型交信を「ラバースタンプQSO」と呼ぶ。
  毎回タイプするのは現実的でないので、

      CQ CQ CQ de <MYCALL> <MYCALL> pse k

  のような雛形を用意し、<MYCALL> のような差し込み記号 (タグ) を実行時に
  実際の値へ置き換えて送信する。これがマクロである。

  コンテストではさらに速度が要るうえ、送信ナンバーの管理という
  「間違えると交信が無効になる」要素が加わる。本ユニットはラバースタンプと
  コンテストの両方を同じ仕組みで扱う。

  fldigi との対応:
  ----------------------------------------------------------------------------
  | fldigi                                   | 本ユニット                     |
  |------------------------------------------|--------------------------------|
  | MACROTEXT::expand()                      | TMacroExpander.Expand          |
  | MACROTEXT::text[] / name[] (固定 48 個)  | TMacroSet (可変長・名前引き)   |
  | macro_types[] のタグ表                   | 内部のタグディスパッチ         |
  | <TX>/<RX> が直接 trx_transmit() を呼ぶ   | TMacroSegment として "返す"    |

  設計上いちばん重要な違い (なぜ文字列を返さないのか):
  ----------------------------------------------------------------------------
  fldigi の expand() は展開しながら副作用 (送信開始/停止、モード変更) を
  その場で実行してしまう。これだと

    - 送信前に「このマクロは何をするか」を確認できない
    - GUI 無し・無線機無しで単体テストできない
    - 「展開はできたが送信はしない (プレビュー)」ができない

  という三つの問題がある。そこで本ユニットは展開結果を
  「文字列断片と操作命令が順番に並んだ列」(TMacroSegment の配列) として
  返すだけにし、実行は呼び出し側に任せる。

      <TX>CQ de <MYCALL> k<RX>
        -> [操作:送信開始] [文字列:"CQ de JI1UUI k"] [操作:受信復帰]

  こうすると、同じ展開結果を「送信する」「画面に見せるだけ」「検査する」の
  どれにも使える。送信前バリデーション (Validate) が成立するのもこの形の
  おかげである。

  コンテスト運用で特に配慮した点:
  ----------------------------------------------------------------------------
  1. 送信ナンバーは "ログするまで進めない"
     <#> を展開しただけでは番号は進まない。CommitSerial を呼んだときだけ
     進む。呼ばれた局に 001 を送ったあと交信不成立でログしなかった場合、
     次の局にも 001 を送るのが正しい (番号を飛ばすとログ照合で減点される)。
     展開のたびに採番する実装だと、再送のたびに番号が飛ぶ。

  2. CW のカットナンバー
     コンテストのCWでは 0 を T、9 を N と短縮して送る慣習がある
     (599 -> 5NN、100 -> ATT)。<#CUT> で出力できるようにした。

  3. 送信したまま受信に戻らないマクロを事前に弾く
     <TX> で始まり <RX> で終わらないマクロは、実行すると電波を出しっぱなしに
     する。コンテスト中に気づかず放置すると被害が大きいので、
     Validate がエラーとして報告する。
  ============================================================================ }
unit MacroEngine;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, DateUtils, StrUtils, fpjson, jsonparser, SafeFileIO;

type
  EMacroError = class(Exception);

  { マクロが呼び出し側に依頼する操作。
    fldigi では expand() の中で直接実行されるが、本ユニットは
    「依頼を返す」だけにして実行を呼び出し側に委ねる。 }
  TMacroActionKind = (
    makTransmit,    // <TX>      送信開始
    makReceive,     // <RX>      受信復帰 (送信バッファを送り切ってから)
    makAbortTx,     // <ABORT>   送信即時中止
    makLog,         // <LOG>     現在の交信をログに記録
    makClearRx,     // <CLRRX>   受信ウィンドウを消去
    makClearTx,     // <CLRTX>   送信ウィンドウを消去
    makSetMode,     // <MODE:x>  モード変更 (Arg にモード名)
    makSetFreq,     // <FREQ:x>  周波数変更 (ArgNum に MHz)
    makIncSerial,   // <INCR>    送信ナンバーを1増やす
    makDecSerial,   // <DECR>    送信ナンバーを1減らす
    makWait         // <WAIT:n>  n 秒待つ (ArgNum に秒)
  );

  TMacroSegmentKind = (
    mskText,        // 送信すべき文字列
    mskAction       // 呼び出し側への操作依頼
  );

  { 展開結果の1断片。文字列と操作が元の順序どおりに並ぶ。 }
  TMacroSegment = record
    Kind: TMacroSegmentKind;
    Text: string;              // mskText のときの本文
    Action: TMacroActionKind;  // mskAction のときの操作
    Arg: string;               // 操作の文字列引数 (<MODE:RTTY> の "RTTY")
    ArgNum: Double;            // 操作の数値引数 (<WAIT:3> の 3)
  end;
  TMacroSegmentArray = array of TMacroSegment;

  TMacroIssueLevel = (
    milInfo,      // 参考情報
    milWarning,   // 送信はできるが意図と違う可能性がある
    milError      // 送信すべきでない
  );

  { 送信前バリデーションの指摘 1件。 }
  TMacroIssue = record
    Level: TMacroIssueLevel;
    Tag: string;        // 原因となったタグ (無い場合は空)
    Message: string;
  end;
  TMacroIssueArray = array of TMacroIssue;

  { 展開の結果一式。 }
  TMacroExpansion = record
    Segments: TMacroSegmentArray;
    Issues: TMacroIssueArray;
    { 展開中に実際に使われた差し込みタグの名前 (大文字, 重複なし)。
      展開後の文字列を見ても「<CALL> が空だった」のか
      「もともと <CALL> を書いていない」のかは区別できない。
      CQ のように相手がいない場面で「相手のコールが空です」と
      言われては困るので、使ったかどうかを展開時に記録しておく。 }
    UsedTags: array of string;

    { すべての mskText を連結したもの。プレビュー表示や
      「実際に電波に乗る文字列」の確認に使う。 }
    function PlainText: string;
    function SegmentCount: Integer;
    function ActionCount: Integer;
    function IssueCount(ALevel: TMacroIssueLevel): Integer;
    { milError が 1 件でもあれば True。送信を止める判断に使う。 }
    function HasErrors: Boolean;
    function HasWarnings: Boolean;
    { 指摘を人が読める1つの文字列にまとめる (改行区切り)。 }
    function IssueText: string;
    { 指定した操作が含まれるか。 }
    function ContainsAction(AKind: TMacroActionKind): Boolean;
    { 指定した差し込みタグが使われたか (名前は大小どちらでもよい)。 }
    function UsesTag(const ATag: string): Boolean;
  end;

  { マクロの用途区分。UI でタブを分けたり、コンテスト中に
    ラグチュー用マクロを隠したりするために持つ。 }
  TMacroCategory = (
    mcGeneral,      // 汎用
    mcRubberStamp,  // ラバースタンプ (定型交信)
    mcContest       // コンテスト
  );

  { --- 展開に使う値の入れ物 ---
    「自局」「相手局」「運用状態」「コンテスト」の4群からなる。
    自局の値は OpProfile.TResolvedStation から流し込む想定。 }
  TMacroContext = class
  private
    FMyCall: string;
    FMyName: string;
    FMyQth: string;
    FMyLocator: string;
    FMyRig: string;
    FMyAntenna: string;
    FMyPowerW: Integer;

    FCall: string;
    FName: string;
    FQth: string;
    FLocator: string;
    FRstSent: string;
    FRstRcvd: string;

    FBand: string;
    FMode: string;
    FFreqMHz: Double;

    FContestName: string;
    FSerialOut: Integer;
    FSerialDigits: Integer;
    FSerialIn: string;
    FExchangeOut: string;
    FExchangeIn: string;

    FFixedUtcNow: TDateTime;
  public
    constructor Create;

    { 現在の UTC。FixedUtcNow が 0 でなければそれを返す
      (テストで時刻を固定するため。時計をモックするより読みやすい)。 }
    function UtcNow: TDateTime;

    { 送信ナンバーを確定して次へ進める。ログ記録が成功した後にだけ呼ぶこと。
      展開 (<#>) では進めない ― 交信不成立で番号を飛ばすと、
      コンテストのログ照合で「相手の受信番号と合わない」減点になる。 }
    procedure CommitSerial;
    procedure ResetSerial(AStart: Integer = 1);

    { 相手局に関する項目だけを消す (次の交信へ移るとき)。
      自局・運用状態・送信ナンバーは残る。 }
    procedure ClearWorkedStation;

    { --- 自局 --- }
    property MyCall: string read FMyCall write FMyCall;
    property MyName: string read FMyName write FMyName;
    property MyQth: string read FMyQth write FMyQth;
    property MyLocator: string read FMyLocator write FMyLocator;
    property MyRig: string read FMyRig write FMyRig;
    property MyAntenna: string read FMyAntenna write FMyAntenna;
    property MyPowerW: Integer read FMyPowerW write FMyPowerW;

    { --- 相手局 --- }
    property Call: string read FCall write FCall;
    property Name: string read FName write FName;
    property Qth: string read FQth write FQth;
    property Locator: string read FLocator write FLocator;
    property RstSent: string read FRstSent write FRstSent;
    property RstRcvd: string read FRstRcvd write FRstRcvd;

    { --- 運用状態 --- }
    property Band: string read FBand write FBand;
    property Mode: string read FMode write FMode;
    property FreqMHz: Double read FFreqMHz write FFreqMHz;

    { --- コンテスト --- }
    property ContestName: string read FContestName write FContestName;
    { これから送る番号。CommitSerial を呼ぶまで変わらない。 }
    property SerialOut: Integer read FSerialOut write FSerialOut;
    { 送信ナンバーのゼロ詰め桁数 (既定 3 = 001)。 }
    property SerialDigits: Integer read FSerialDigits write FSerialDigits;
    property SerialIn: string read FSerialIn write FSerialIn;
    property ExchangeOut: string read FExchangeOut write FExchangeOut;
    property ExchangeIn: string read FExchangeIn write FExchangeIn;

    { 0 以外なら UtcNow がこの値を返す (テスト用)。 }
    property FixedUtcNow: TDateTime read FFixedUtcNow write FFixedUtcNow;
  end;

  { 1つのマクロ定義。 }
  TMacroDefinition = class
  private
    FName: string;
    FText: string;
    FNote: string;
    FCategory: TMacroCategory;
  public
    constructor Create(const AName, AText: string;
      ACategory: TMacroCategory = mcGeneral; const ANote: string = '');
    property Name: string read FName write FName;
    property Text: string read FText write FText;
    property Note: string read FNote write FNote;
    property Category: TMacroCategory read FCategory write FCategory;
  end;

  { マクロの一覧。ファンクションキーへの割り当ては呼び出し側 (UI) の責務とし、
    ここでは「名前で引ける定義の集合」に徹する。 }
  TMacroSet = class
  private
    FItems: array of TMacroDefinition;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TMacroDefinition;
    procedure CheckIndex(AIndex: Integer);
  public
    destructor Destroy; override;
    procedure Clear;

    function Add(const AName, AText: string;
      ACategory: TMacroCategory = mcGeneral;
      const ANote: string = ''): TMacroDefinition;
    { 同名があれば内容を差し替え、無ければ追加する。 }
    function AddOrReplace(const AName, AText: string;
      ACategory: TMacroCategory = mcGeneral;
      const ANote: string = ''): TMacroDefinition;
    function Find(const AName: string): TMacroDefinition;
    function IndexOf(const AName: string): Integer;
    function Remove(const AName: string): Boolean;

    { ラバースタンプ交信とコンテスト運用の標準セットを登録する。
      「何から書き始めればいいか分からない」状態を避けるための出発点であり、
      利用者が自由に編集して使うことを前提としている。 }
    procedure RegisterBuiltins;

    procedure LoadFromFile(const AFileName: string);
    procedure SaveToFile(const AFileName: string);
    function ToJsonString: string;
    procedure FromJsonString(const AJson: string);

    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TMacroDefinition read GetItem; default;
  end;

  { マクロ展開器。状態を持たないので 1 個を使い回してよい。 }
  TMacroExpander = class
  private
    FMacros: TMacroSet;      // <MACRO:名前> の解決先。nil 可 (参照のみ)。
    FMaxDepth: Integer;
    FStrictUnknownTags: Boolean;
    procedure ExpandInto(const AText: string; ACtx: TMacroContext;
      var AResult: TMacroExpansion; ADepth: Integer;
      var APending: string);
    procedure Flush(var AResult: TMacroExpansion; var APending: string);
    { 操作を積む。文字列と操作の順序を保つため、溜まっている文字列を
      先に確定させてから積むこと。そのため APending も受け取る。 }
    procedure AddAction(var AResult: TMacroExpansion; var APending: string;
      AKind: TMacroActionKind; const AArg: string; AArgNum: Double);
    procedure AddIssue(var AResult: TMacroExpansion; ALevel: TMacroIssueLevel;
      const ATag, AMessage: string);
    { 差し込みタグを使ったことを記録する (Validate が使う)。 }
    procedure NoteTagUsed(var AResult: TMacroExpansion; const ATag: string);
    { タグ 1 個を処理する。文字列に展開されるなら APending に足し、
      操作なら AResult へ積む。戻り値: 既知のタグだったか。
      ATagName には正規化した (大文字・引数を除いた) タグ名を返す。 }
    function HandleTagCore(const ATagBody: string; ACtx: TMacroContext;
      var AResult: TMacroExpansion; ADepth: Integer;
      var APending: string; out ATagName: string): Boolean;
    { HandleTagCore を呼び、既知タグだった場合だけ使用記録を残す。 }
    function HandleTag(const ATagBody: string; ACtx: TMacroContext;
      var AResult: TMacroExpansion; ADepth: Integer;
      var APending: string): Boolean;
  public
    constructor Create(AMacros: TMacroSet = nil);

    { 本文を展開する。 }
    function Expand(const AText: string; ACtx: TMacroContext): TMacroExpansion;
    { 登録済みマクロを名前で展開する。 }
    function ExpandNamed(const AName: string; ACtx: TMacroContext): TMacroExpansion;

    { 展開結果を送信前に検査し、Issues を追加して返す。
      Expand が「書き方の問題」(未知タグ等) を見るのに対し、こちらは
      「今この状況で送っていいか」を見る。 }
    function Validate(const AExpansion: TMacroExpansion;
      ACtx: TMacroContext): TMacroExpansion;

    { 展開と検査をまとめて行う (送信ボタンから呼ぶ入口)。 }
    function Prepare(const AText: string; ACtx: TMacroContext): TMacroExpansion;
    function PrepareNamed(const AName: string; ACtx: TMacroContext): TMacroExpansion;

    { <MACRO:名前> の解決先。 }
    property Macros: TMacroSet read FMacros write FMacros;
    { <MACRO:...> の入れ子の深さ上限 (既定 8)。無限再帰を止める。 }
    property MaxDepth: Integer read FMaxDepth write FMaxDepth;
    { True にすると未知タグを milError にする (既定 False = 警告)。 }
    property StrictUnknownTags: Boolean
      read FStrictUnknownTags write FStrictUnknownTags;
  end;

  { --- マクロを実際に実行するための宿主 ---
    展開結果 (TMacroSegment の列) を「誰が」実行するかを抽象化する。
    実機ではフォームがこれを実装し、TModemEngine / TCustomRigControl /
    TQsoLogbook へ配線する。テストでは記録するだけの実装を差し込む。

    この境界を作る理由は 2 つある。
      1. マクロの実行順序という論理を、GUI や無線機なしで検証できる
      2. fldigi のように展開器が trx_transmit() を直接呼ぶ形にすると、
         マクロを 1 つ試すたびに実機一式が要る }
  TMacroHost = class abstract
  public
    { 送信バッファへ本文を積む (実際に電波に乗るのは送信中のみ)。 }
    procedure SendText(const AText: string); virtual; abstract;
    procedure StartTransmit; virtual; abstract;
    { 送信バッファを送り切ってから受信へ戻る。 }
    procedure StopTransmit; virtual; abstract;
    { 送信を即時中止する (バッファは捨てる)。 }
    procedure AbortTransmit; virtual; abstract;
    { 現在の交信をログに記録する。戻り値が True のときだけ
      送信ナンバーが次へ進む。 }
    function LogCurrentQso: Boolean; virtual; abstract;
    procedure ClearRxWindow; virtual; abstract;
    procedure ClearTxWindow; virtual; abstract;
    procedure SetMode(const AMode: string); virtual; abstract;
    procedure SetFreqMHz(AFreqMHz: Double); virtual; abstract;
    { ASeconds 秒待つ。実装側で中断可能にしてよい。 }
    procedure Wait(ASeconds: Double); virtual; abstract;
  end;

  { マクロ実行の結果。 }
  TMacroRunResult = record
    Executed: Boolean;      // 実行したか (エラーで拒否した場合 False)
    ActionsRun: Integer;
    TextSent: Integer;      // 送信バッファへ積んだ回数
    Logged: Boolean;        // ログ記録が行われ、成功したか
    SerialAdvanced: Boolean;// 送信ナンバーが進んだか
    RefusalReason: string;  // Executed=False のときの理由
  end;

  { 展開結果を宿主へ流し込む実行器。 }
  TMacroRunner = class
  private
    FHost: TMacroHost;
    FAllowWithWarnings: Boolean;
  public
    constructor Create(AHost: TMacroHost);

    { 展開結果を実行する。
      エラー (milError) が 1 件でもあれば実行を拒否する。これが
      「送信前バリデーション」が実効性を持つ唯一の場所である
      ― 検査しても実行を止めなければ意味がない。
      AForce=True で強行できるが、通常は使わない。 }
    function Run(const AExpansion: TMacroExpansion; ACtx: TMacroContext;
      AForce: Boolean = False): TMacroRunResult;

    property Host: TMacroHost read FHost write FHost;
    { 警告 (milWarning) があっても実行するか (既定 True)。
      False にすると「RST が空」等でも止まる。 }
    property AllowWithWarnings: Boolean
      read FAllowWithWarnings write FAllowWithWarnings;
  end;

{ 送信ナンバーをゼロ詰めした文字列にする (3桁なら 7 -> "007")。 }
function FormatSerial(AValue, ADigits: Integer): string;

{ CW コンテストのカットナンバー表記に変換する (0 -> T, 9 -> N)。
  599 -> 5NN、100 -> ATT ではなく 1TT (1 は短縮しないのが安全側)。
  数字以外はそのまま通す。 }
function ToCutNumbers(const AText: string): string;

function MacroCategoryToStr(ACategory: TMacroCategory): string;
function StrToMacroCategory(const AStr: string): TMacroCategory;
function MacroIssueLevelToStr(ALevel: TMacroIssueLevel): string;

implementation

const
  MACRO_JSON_VERSION = 1;
  DEFAULT_SERIAL_DIGITS = 3;
  DEFAULT_MAX_DEPTH = 8;

{ ============================ 補助関数 ============================ }

function FormatSerial(AValue, ADigits: Integer): string;
var
  s: string;
begin
  if ADigits < 1 then ADigits := 1;
  if ADigits > 9 then ADigits := 9;
  s := IntToStr(Abs(AValue));
  while Length(s) < ADigits do
    s := '0' + s;
  if AValue < 0 then
    s := '-' + s;
  Result := s;
end;

function ToCutNumbers(const AText: string): string;
var
  i: Integer;
begin
  Result := AText;
  for i := 1 to Length(Result) do
    case Result[i] of
      '0': Result[i] := 'T';
      '9': Result[i] := 'N';
    end;
end;

function MacroCategoryToStr(ACategory: TMacroCategory): string;
begin
  case ACategory of
    mcRubberStamp: Result := 'rubberstamp';
    mcContest:     Result := 'contest';
  else
    Result := 'general';
  end;
end;

function StrToMacroCategory(const AStr: string): TMacroCategory;
var
  s: string;
begin
  s := LowerCase(Trim(AStr));
  if s = 'rubberstamp' then Result := mcRubberStamp
  else if s = 'contest' then Result := mcContest
  else Result := mcGeneral;
end;

function MacroIssueLevelToStr(ALevel: TMacroIssueLevel): string;
begin
  case ALevel of
    milError:   Result := 'エラー';
    milWarning: Result := '警告';
  else
    Result := '情報';
  end;
end;

{ ============================ TMacroExpansion ============================ }

function TMacroExpansion.PlainText: string;
var
  i: Integer;
  sb: string;
begin
  sb := '';
  for i := 0 to High(Segments) do
    if Segments[i].Kind = mskText then
      sb := sb + Segments[i].Text;
  Result := sb;
end;

function TMacroExpansion.SegmentCount: Integer;
begin
  Result := Length(Segments);
end;

function TMacroExpansion.ActionCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Segments) do
    if Segments[i].Kind = mskAction then
      Inc(Result);
end;

function TMacroExpansion.IssueCount(ALevel: TMacroIssueLevel): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Issues) do
    if Issues[i].Level = ALevel then
      Inc(Result);
end;

function TMacroExpansion.HasErrors: Boolean;
begin
  Result := IssueCount(milError) > 0;
end;

function TMacroExpansion.HasWarnings: Boolean;
begin
  Result := IssueCount(milWarning) > 0;
end;

function TMacroExpansion.IssueText: string;
var
  i: Integer;
  line: string;
begin
  Result := '';
  for i := 0 to High(Issues) do
  begin
    line := '[' + MacroIssueLevelToStr(Issues[i].Level) + '] ';
    if Issues[i].Tag <> '' then
      line := line + '<' + Issues[i].Tag + '>: ';
    line := line + Issues[i].Message;
    if Result <> '' then
      Result := Result + sLineBreak;
    Result := Result + line;
  end;
end;

function TMacroExpansion.ContainsAction(AKind: TMacroActionKind): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Segments) do
    if (Segments[i].Kind = mskAction) and (Segments[i].Action = AKind) then
      Exit(True);
  Result := False;
end;

function TMacroExpansion.UsesTag(const ATag: string): Boolean;
var
  i: Integer;
  key: string;
begin
  key := UpperCase(Trim(ATag));
  for i := 0 to High(UsedTags) do
    if UsedTags[i] = key then
      Exit(True);
  Result := False;
end;

{ ============================ TMacroContext ============================ }

constructor TMacroContext.Create;
begin
  inherited Create;
  FMyPowerW := 0;
  FFreqMHz := 0;
  FSerialOut := 1;
  FSerialDigits := DEFAULT_SERIAL_DIGITS;
  FFixedUtcNow := 0;
end;

function TMacroContext.UtcNow: TDateTime;
begin
  if FFixedUtcNow <> 0 then
    Result := FFixedUtcNow
  else
    Result := LocalTimeToUniversal(Now);
end;

procedure TMacroContext.CommitSerial;
begin
  Inc(FSerialOut);
end;

procedure TMacroContext.ResetSerial(AStart: Integer);
begin
  FSerialOut := AStart;
end;

procedure TMacroContext.ClearWorkedStation;
begin
  FCall := '';
  FName := '';
  FQth := '';
  FLocator := '';
  FRstRcvd := '';
  FSerialIn := '';
  FExchangeIn := '';
end;

{ ============================ TMacroDefinition ============================ }

constructor TMacroDefinition.Create(const AName, AText: string;
  ACategory: TMacroCategory; const ANote: string);
begin
  inherited Create;
  FName := AName;
  FText := AText;
  FCategory := ACategory;
  FNote := ANote;
end;

{ ============================ TMacroSet ============================ }

destructor TMacroSet.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TMacroSet.Clear;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Free;
  SetLength(FItems, 0);
end;

function TMacroSet.GetCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TMacroSet.CheckIndex(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then
    raise EMacroError.CreateFmt(
      'マクロの添字が範囲外です (要求 %d / 登録数 %d)', [AIndex, Length(FItems)]);
end;

function TMacroSet.GetItem(AIndex: Integer): TMacroDefinition;
begin
  CheckIndex(AIndex);
  Result := FItems[AIndex];
end;

function TMacroSet.IndexOf(const AName: string): Integer;
var
  i: Integer;
  key: string;
begin
  key := UpperCase(Trim(AName));
  for i := 0 to High(FItems) do
    if UpperCase(FItems[i].Name) = key then
      Exit(i);
  Result := -1;
end;

function TMacroSet.Find(const AName: string): TMacroDefinition;
var
  idx: Integer;
begin
  idx := IndexOf(AName);
  if idx < 0 then
    Result := nil
  else
    Result := FItems[idx];
end;

function TMacroSet.Add(const AName, AText: string;
  ACategory: TMacroCategory; const ANote: string): TMacroDefinition;
var
  n: Integer;
begin
  if Trim(AName) = '' then
    raise EMacroError.Create('マクロ名が空です');
  if IndexOf(AName) >= 0 then
    raise EMacroError.CreateFmt('マクロ名が重複しています: %s', [AName]);
  Result := TMacroDefinition.Create(Trim(AName), AText, ACategory, ANote);
  n := Length(FItems);
  SetLength(FItems, n + 1);
  FItems[n] := Result;
end;

function TMacroSet.AddOrReplace(const AName, AText: string;
  ACategory: TMacroCategory; const ANote: string): TMacroDefinition;
var
  idx: Integer;
begin
  idx := IndexOf(AName);
  if idx < 0 then
    Exit(Add(AName, AText, ACategory, ANote));
  Result := FItems[idx];
  Result.Text := AText;
  Result.Category := ACategory;
  Result.Note := ANote;
end;

function TMacroSet.Remove(const AName: string): Boolean;
var
  idx, i: Integer;
begin
  idx := IndexOf(AName);
  if idx < 0 then Exit(False);
  FItems[idx].Free;
  for i := idx to High(FItems) - 1 do
    FItems[i] := FItems[i + 1];
  SetLength(FItems, Length(FItems) - 1);
  Result := True;
end;

procedure TMacroSet.RegisterBuiltins;
begin
  { --- ラバースタンプ交信の標準セット ---
    fldigi の既定マクロ (macros.cxx の loadDefaults) を参考にしつつ、
    国内運用でそのまま使える文面にしてある。
    <TX> で始めて <RX> で終える形を徹底しているのは、
    「送信したまま戻らない」事故を雛形の段階で防ぐため。 }
  AddOrReplace('CQ',
    '<TX>' + sLineBreak +
    'CQ CQ CQ de <MYCALL> <MYCALL> <MYCALL> pse k' + sLineBreak +
    '<RX>',
    mcRubberStamp, 'CQ を出す');

  AddOrReplace('応答',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL> <MYCALL> kn' + sLineBreak +
    '<RX>',
    mcRubberStamp, '呼んできた局に応答する');

  AddOrReplace('レポート',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL>' + sLineBreak +
    'GA OM ur rst <RST> <RST>' + sLineBreak +
    'QTH is <MYQTH> <MYQTH>' + sLineBreak +
    'name is <MYNAME> <MYNAME>' + sLineBreak +
    'hw? <CALL> de <MYCALL> kn' + sLineBreak +
    '<RX>',
    mcRubberStamp, 'RST・QTH・名前を送る (ラバースタンプの本体)');

  AddOrReplace('リグ紹介',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL>' + sLineBreak +
    'tnx fb rpt. rig is <MYRIG> pwr <MYPWR>W' + sLineBreak +
    'ant is <MYANT>' + sLineBreak +
    '<CALL> de <MYCALL> kn' + sLineBreak +
    '<RX>',
    mcRubberStamp, 'リグ・アンテナ・出力を送る');

  AddOrReplace('73',
    '<TX>' + sLineBreak +
    '<CALL> de <MYCALL>' + sLineBreak +
    'tnx fb qso <NAME>. hpe cuagn. 73 es gl' + sLineBreak +
    '<CALL> de <MYCALL> sk' + sLineBreak +
    '<LOG><RX>',
    mcRubberStamp, '交信を終えてログに記録する');

  AddOrReplace('QRZ?',
    '<TX>' + sLineBreak +
    'QRZ? de <MYCALL> k' + sLineBreak +
    '<RX>',
    mcRubberStamp, 'コールサインが取れなかったときの聞き返し');

  { --- コンテストの標準セット ---
    ラバースタンプと違い、余計な語を入れないのが正義である。
    ログ記録 (<LOG>) を交換の直後に置き、送信ナンバーの確定を
    「相手に送った瞬間」ではなく「ログした瞬間」に紐付けている。 }
  AddOrReplace('CQコンテスト',
    '<TX>CQ TEST de <MYCALL> <MYCALL> TEST<RX>',
    mcContest, 'コンテストの CQ (短く速く)');

  AddOrReplace('交換',
    '<TX><CALL> <RST><#> <RST><#><RX>',
    mcContest, 'レポートと送信ナンバーを送る');

  AddOrReplace('交換(カット)',
    '<TX><CALL> <RST><#CUT> <RST><#CUT><RX>',
    mcContest, 'CW用にカットナンバー (0=T, 9=N) で送る');

  AddOrReplace('TU',
    '<TX>TU <MYCALL> TEST<LOG><RX>',
    mcContest, '交信成立。ログに記録して次の CQ へ');

  AddOrReplace('AGN?',
    '<TX>AGN AGN<RX>',
    mcContest, '再送依頼');

  AddOrReplace('NR?',
    '<TX>NR? NR?<RX>',
    mcContest, '送信ナンバーの再送依頼');
end;

function TMacroSet.ToJsonString: string;
var
  root: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  i: Integer;
begin
  root := TJSONObject.Create;
  try
    root.Add('version', MACRO_JSON_VERSION);
    arr := TJSONArray.Create;
    root.Add('macros', arr);
    for i := 0 to High(FItems) do
    begin
      o := TJSONObject.Create;
      o.Add('name', FItems[i].Name);
      o.Add('text', FItems[i].Text);
      o.Add('note', FItems[i].Note);
      o.Add('category', MacroCategoryToStr(FItems[i].Category));
      arr.Add(o);
    end;
    Result := root.FormatJSON;
  finally
    root.Free;
  end;
end;

procedure TMacroSet.FromJsonString(const AJson: string);
var
  data: TJSONData;
  root: TJSONObject;
  arr: TJSONArray;
  o: TJSONObject;
  i: Integer;
  nm, tx, nt, cat: string;
begin
  Clear;
  if Trim(AJson) = '' then Exit;
  data := GetJSON(AJson);
  try
    if not (data is TJSONObject) then
      raise EMacroError.Create('マクロ定義の最上位が JSON オブジェクトではありません');
    root := TJSONObject(data);
    if root.IndexOfName('macros') < 0 then Exit;
    if not (root.Items[root.IndexOfName('macros')] is TJSONArray) then
      raise EMacroError.Create('"macros" が配列ではありません');
    arr := TJSONArray(root.Items[root.IndexOfName('macros')]);
    for i := 0 to arr.Count - 1 do
    begin
      { 手編集で壊れた項目は、その 1 件だけ読み飛ばす。
        1 件の型違いでマクロ全体が読めなくなる方が実害が大きい。 }
      if not (arr.Items[i] is TJSONObject) then Continue;
      o := TJSONObject(arr.Items[i]);
      nm := o.Get('name', '');
      if Trim(nm) = '' then Continue;
      if IndexOf(nm) >= 0 then Continue;   // 重複は先勝ち
      tx := o.Get('text', '');
      nt := o.Get('note', '');
      cat := o.Get('category', 'general');
      Add(nm, tx, StrToMacroCategory(cat), nt);
    end;
  finally
    data.Free;
  end;
end;

procedure TMacroSet.LoadFromFile(const AFileName: string);
begin
  if not FileExists(AFileName) then
  begin
    Clear;
    Exit;
  end;
  FromJsonString(LoadTextRaw(AFileName));
end;

procedure TMacroSet.SaveToFile(const AFileName: string);
begin
  SaveTextAtomic(AFileName, ToJsonString);
end;

{ ============================ TMacroExpander ============================ }

constructor TMacroExpander.Create(AMacros: TMacroSet);
begin
  inherited Create;
  FMacros := AMacros;
  FMaxDepth := DEFAULT_MAX_DEPTH;
  FStrictUnknownTags := False;
end;

procedure TMacroExpander.Flush(var AResult: TMacroExpansion;
  var APending: string);
var
  n: Integer;
begin
  if APending = '' then Exit;
  n := Length(AResult.Segments);
  SetLength(AResult.Segments, n + 1);
  AResult.Segments[n].Kind := mskText;
  AResult.Segments[n].Text := APending;
  AResult.Segments[n].Action := makTransmit;   // 未使用
  AResult.Segments[n].Arg := '';
  AResult.Segments[n].ArgNum := 0;
  APending := '';
end;

procedure TMacroExpander.AddAction(var AResult: TMacroExpansion;
  var APending: string; AKind: TMacroActionKind;
  const AArg: string; AArgNum: Double);
var
  n: Integer;
begin
  { ここで確定させないと「操作の前にあった文字列」が操作の後ろに回る。 }
  Flush(AResult, APending);
  n := Length(AResult.Segments);
  SetLength(AResult.Segments, n + 1);
  AResult.Segments[n].Kind := mskAction;
  AResult.Segments[n].Text := '';
  AResult.Segments[n].Action := AKind;
  AResult.Segments[n].Arg := AArg;
  AResult.Segments[n].ArgNum := AArgNum;
end;

procedure TMacroExpander.AddIssue(var AResult: TMacroExpansion;
  ALevel: TMacroIssueLevel; const ATag, AMessage: string);
var
  n: Integer;
begin
  n := Length(AResult.Issues);
  SetLength(AResult.Issues, n + 1);
  AResult.Issues[n].Level := ALevel;
  AResult.Issues[n].Tag := ATag;
  AResult.Issues[n].Message := AMessage;
end;

procedure TMacroExpander.NoteTagUsed(var AResult: TMacroExpansion;
  const ATag: string);
var
  n: Integer;
begin
  if AResult.UsesTag(ATag) then Exit;
  n := Length(AResult.UsedTags);
  SetLength(AResult.UsedTags, n + 1);
  AResult.UsedTags[n] := UpperCase(Trim(ATag));
end;

function TMacroExpander.HandleTag(const ATagBody: string; ACtx: TMacroContext;
  var AResult: TMacroExpansion; ADepth: Integer;
  var APending: string): Boolean;
var
  tagName: string;
begin
  Result := HandleTagCore(ATagBody, ACtx, AResult, ADepth, APending, tagName);
  if Result then
    NoteTagUsed(AResult, tagName);
end;

function TMacroExpander.HandleTagCore(const ATagBody: string;
  ACtx: TMacroContext; var AResult: TMacroExpansion; ADepth: Integer;
  var APending: string; out ATagName: string): Boolean;
var
  upperTag, tagName, arg: string;
  colonPos: Integer;
  num: Double;
  sub: TMacroDefinition;
  fs: TFormatSettings;
begin
  Result := True;
  upperTag := UpperCase(Trim(ATagBody));

  { 引数付きタグ (<MODE:RTTY>) を名前と引数に割る。
    引数側は大小をそのまま残す (モード名やマクロ名は原文が要る)。 }
  colonPos := Pos(':', upperTag);
  if colonPos > 0 then
  begin
    tagName := Copy(upperTag, 1, colonPos - 1);
    arg := Trim(Copy(Trim(ATagBody), colonPos + 1, MaxInt));
  end
  else
  begin
    tagName := upperTag;
    arg := '';
  end;

  ATagName := tagName;

  { --- 自局 --- }
  if tagName = 'MYCALL' then APending := APending + ACtx.MyCall
  else if tagName = 'MYNAME' then APending := APending + ACtx.MyName
  else if tagName = 'MYQTH' then APending := APending + ACtx.MyQth
  else if tagName = 'MYLOC' then APending := APending + ACtx.MyLocator
  else if tagName = 'MYRIG' then APending := APending + ACtx.MyRig
  else if (tagName = 'MYANT') or (tagName = 'ANTENNA') then
    APending := APending + ACtx.MyAntenna
  else if tagName = 'MYPWR' then
  begin
    if ACtx.MyPowerW > 0 then
      APending := APending + IntToStr(ACtx.MyPowerW);
  end

  { --- 相手局 --- }
  else if tagName = 'CALL' then APending := APending + ACtx.Call
  else if tagName = 'NAME' then APending := APending + ACtx.Name
  else if tagName = 'QTH' then APending := APending + ACtx.Qth
  else if tagName = 'LOC' then APending := APending + ACtx.Locator
  else if (tagName = 'RST') or (tagName = 'RSTS') then
    APending := APending + ACtx.RstSent
  else if tagName = 'RSTR' then APending := APending + ACtx.RstRcvd

  { --- 運用状態 --- }
  else if tagName = 'BAND' then APending := APending + ACtx.Band
  else if tagName = 'MODE' then
  begin
    if arg = '' then
      APending := APending + ACtx.Mode
    else
      AddAction(AResult, APending, makSetMode, arg, 0);
  end
  else if tagName = 'FREQ' then
  begin
    if arg = '' then
    begin
      fs := DefaultFormatSettings;
      fs.DecimalSeparator := '.';   // ADIF/無線の慣習に合わせ小数点は必ず '.'
      APending := APending + FormatFloat('0.000', ACtx.FreqMHz, fs);
    end
    else
    begin
      fs := DefaultFormatSettings;
      fs.DecimalSeparator := '.';
      if not TryStrToFloat(arg, num, fs) then
      begin
        AddIssue(AResult, milError, 'FREQ',
          '周波数として読めません: ' + arg);
        Exit(True);
      end;
      AddAction(AResult, APending, makSetFreq, arg, num);
    end;
  end

  { --- 日時 (すべて UTC。ログも交信も UTC で扱うため) --- }
  else if tagName = 'TIME' then
    APending := APending + FormatDateTime('hhnn', ACtx.UtcNow) + 'Z'
  else if tagName = 'DATE' then
    APending := APending + FormatDateTime('yyyymmdd', ACtx.UtcNow)
  else if tagName = 'ZDT' then
    APending := APending +
      FormatDateTime('yyyy-mm-dd hh:nn', ACtx.UtcNow) + 'Z'

  { --- コンテスト --- }
  else if tagName = 'CNTST' then APending := APending + ACtx.ContestName
  else if (tagName = '#') or (tagName = 'SERIAL') then
    APending := APending + FormatSerial(ACtx.SerialOut, ACtx.SerialDigits)
  else if (tagName = '#CUT') or (tagName = 'SERIALCUT') then
    APending := APending +
      ToCutNumbers(FormatSerial(ACtx.SerialOut, ACtx.SerialDigits))
  else if tagName = 'SERIALIN' then APending := APending + ACtx.SerialIn
  else if tagName = 'XOUT' then APending := APending + ACtx.ExchangeOut
  else if tagName = 'XIN' then APending := APending + ACtx.ExchangeIn
  else if tagName = 'INCR' then AddAction(AResult, APending, makIncSerial, '', 0)
  else if tagName = 'DECR' then AddAction(AResult, APending, makDecSerial, '', 0)

  { --- 操作 --- }
  else if tagName = 'TX' then AddAction(AResult, APending, makTransmit, '', 0)
  else if tagName = 'RX' then AddAction(AResult, APending, makReceive, '', 0)
  else if tagName = 'ABORT' then AddAction(AResult, APending, makAbortTx, '', 0)
  else if tagName = 'LOG' then AddAction(AResult, APending, makLog, '', 0)
  else if tagName = 'CLRRX' then AddAction(AResult, APending, makClearRx, '', 0)
  else if tagName = 'CLRTX' then AddAction(AResult, APending, makClearTx, '', 0)
  else if tagName = 'WAIT' then
  begin
    fs := DefaultFormatSettings;
    fs.DecimalSeparator := '.';
    if not TryStrToFloat(arg, num, fs) then
    begin
      AddIssue(AResult, milError, 'WAIT', '秒数として読めません: ' + arg);
      Exit(True);
    end;
    if (num < 0) or (num > 600) then
    begin
      AddIssue(AResult, milError, 'WAIT',
        '待ち時間が範囲外です (0～600秒): ' + arg);
      Exit(True);
    end;
    AddAction(AResult, APending, makWait, arg, num);
  end

  { --- 入れ子マクロ --- }
  else if tagName = 'MACRO' then
  begin
    if FMacros = nil then
    begin
      AddIssue(AResult, milError, 'MACRO',
        'マクロ集が設定されていないため <MACRO:' + arg + '> を展開できません');
      Exit(True);
    end;
    if ADepth >= FMaxDepth then
    begin
      AddIssue(AResult, milError, 'MACRO',
        'マクロの入れ子が深すぎます (上限 ' + IntToStr(FMaxDepth) +
        ')。循環参照になっていないか確認してください: ' + arg);
      Exit(True);
    end;
    sub := FMacros.Find(arg);
    if sub = nil then
    begin
      AddIssue(AResult, milError, 'MACRO',
        '参照先のマクロが見つかりません: ' + arg);
      Exit(True);
    end;
    ExpandInto(sub.Text, ACtx, AResult, ADepth + 1, APending);
  end

  else
    Result := False;   // 未知のタグ
end;

procedure TMacroExpander.ExpandInto(const AText: string; ACtx: TMacroContext;
  var AResult: TMacroExpansion; ADepth: Integer; var APending: string);
var
  i, gtPos: Integer;
  body: string;
begin
  i := 1;
  while i <= Length(AText) do
  begin
    if AText[i] <> '<' then
    begin
      APending := APending + AText[i];
      Inc(i);
      Continue;
    end;

    gtPos := PosEx('>', AText, i + 1);
    if gtPos = 0 then
    begin
      { 閉じ '>' が無い。タグではなく本文の '<' として扱う
        (「<」を含む普通の文章を消してしまわないため)。 }
      APending := APending + Copy(AText, i, MaxInt);
      Break;
    end;

    body := Copy(AText, i + 1, gtPos - i - 1);

    { 文字列側は溜めておき、操作が入る直前で切り出す。
      こうすると「文字列 → 操作 → 文字列」の順序が保たれる。 }
    if not HandleTag(body, ACtx, AResult, ADepth, APending) then
    begin
      { 未知のタグ。原文のまま残し、指摘だけ出す。
        勝手に消すと「送ったつもりの文が抜けている」ことに気づけない。 }
      APending := APending + '<' + body + '>';
      if FStrictUnknownTags then
        AddIssue(AResult, milError, body, '未知のタグです')
      else
        AddIssue(AResult, milWarning, body,
          '未知のタグです。そのままの文字列として送信されます');
    end;
    i := gtPos + 1;
  end;
end;

function TMacroExpander.Expand(const AText: string;
  ACtx: TMacroContext): TMacroExpansion;
var
  pending: string;
  i, n: Integer;
  merged: TMacroSegmentArray;
begin
  if ACtx = nil then
    raise EMacroError.Create('展開コンテキストが nil です');
  Result.Segments := nil;
  Result.Issues := nil;
  Result.UsedTags := nil;
  pending := '';

  ExpandInto(AText, ACtx, Result, 0, pending);

  { 末尾に残った文字列を確定 }
  Flush(Result, pending);

  { 連続する文字列断片をまとめる (実行側が扱いやすいように) }
  SetLength(merged, 0);
  for i := 0 to High(Result.Segments) do
  begin
    n := Length(merged);
    if (Result.Segments[i].Kind = mskText) and (n > 0) and
       (merged[n - 1].Kind = mskText) then
      merged[n - 1].Text := merged[n - 1].Text + Result.Segments[i].Text
    else
    begin
      SetLength(merged, n + 1);
      merged[n] := Result.Segments[i];
    end;
  end;
  Result.Segments := merged;
end;

function TMacroExpander.ExpandNamed(const AName: string;
  ACtx: TMacroContext): TMacroExpansion;
var
  def: TMacroDefinition;
begin
  if FMacros = nil then
    raise EMacroError.Create('マクロ集が設定されていません');
  def := FMacros.Find(AName);
  if def = nil then
    raise EMacroError.CreateFmt('マクロが見つかりません: %s', [AName]);
  Result := Expand(def.Text, ACtx);
end;

function TMacroExpander.Validate(const AExpansion: TMacroExpansion;
  ACtx: TMacroContext): TMacroExpansion;
{ 「今この状況で送っていいか」を見る。Expand が見るのは書き方の問題
  (未知タグ・引数の不正) で、こちらが見るのは運用上の問題である。

  実際に困るのは次の 4 つ:
    1. 送信したまま受信に戻らない → 電波を出しっぱなしにする
    2. 送信開始より前に本文がある → その文は電波に乗らない
    3. 差し込む値が空 → "de  de " のような文を送ってしまう
    4. ログ操作があるのに交信内容が埋まっていない → 空レコードが残る

  3 の判定には「そのタグを実際に使ったか」が要る。展開後の文字列を見ても
  「<CALL> が空だった」のか「もともと書いていない」のかは区別できず、
  CQ マクロに対して「相手のコールが空です」と言ってしまう。
  そこで展開時に記録した UsedTags を使う。 }
var
  i: Integer;
  txSeen, rxAfterTx, textBeforeTx, hasLog, hasText: Boolean;

  procedure Note(ALevel: TMacroIssueLevel; const ATag, AMsg: string);
  begin
    AddIssue(Result, ALevel, ATag, AMsg);
  end;

  { 差し込みタグを使っているのに値が空、という指摘。 }
  procedure RequireValue(const ATag, AValue, ALabel: string;
    ALevel: TMacroIssueLevel);
  begin
    if AExpansion.UsesTag(ATag) and (Trim(AValue) = '') then
      Note(ALevel, ATag, ALabel + 'が空のまま送信しようとしています');
  end;

begin
  Result := AExpansion;   // 指摘を足して返す (展開時の指摘は残す)
  if ACtx = nil then
    raise EMacroError.Create('検査コンテキストが nil です');

  txSeen := False;
  rxAfterTx := False;
  textBeforeTx := False;
  hasLog := False;
  hasText := False;

  for i := 0 to High(Result.Segments) do
    if Result.Segments[i].Kind = mskText then
    begin
      if Trim(Result.Segments[i].Text) <> '' then
      begin
        hasText := True;
        if not txSeen then
          textBeforeTx := True;
      end;
    end
    else
      case Result.Segments[i].Action of
        makTransmit:
          begin
            txSeen := True;
            rxAfterTx := False;   { 二度目の <TX> 以降を改めて見る }
          end;
        makReceive:
          if txSeen then rxAfterTx := True;
        makLog:
          hasLog := True;
      else
        ;
      end;

  { --- 1. 送信したまま戻らない (コンテスト中に最も痛い事故) --- }
  if txSeen and (not rxAfterTx) then
    Note(milError, 'TX',
      '送信を開始したあと受信に戻る <RX> がありません。' +
      'このまま実行すると電波を出し続けます');

  { --- 2. 送信開始前の本文は電波に乗らない --- }
  if textBeforeTx and txSeen then
    Note(milWarning, 'TX',
      '<TX> より前に本文があります。この部分は送信されません');

  if hasText and (not txSeen) then
    Note(milInfo, '',
      '<TX> がありません。本文は送信ウィンドウに入るだけで送信はされません');

  { --- 3. 差し込む値が空のまま --- }
  { 自局コールは、使っていれば必ず必要。 }
  RequireValue('MYCALL', ACtx.MyCall, '自局のコールサイン', milError);
  { 相手コールは、使っているのに空なら交信が成立しない。 }
  RequireValue('CALL', ACtx.Call, '相手局のコールサイン', milError);
  { 以下は空でも交信は成立するので警告どまり。 }
  RequireValue('RST', ACtx.RstSent, '送信 RST', milWarning);
  RequireValue('RSTS', ACtx.RstSent, '送信 RST', milWarning);
  RequireValue('RSTR', ACtx.RstRcvd, '受信 RST', milWarning);
  RequireValue('NAME', ACtx.Name, '相手局の名前', milWarning);
  RequireValue('QTH', ACtx.Qth, '相手局の QTH', milWarning);
  RequireValue('LOC', ACtx.Locator, '相手局のグリッドロケータ', milWarning);
  RequireValue('MYNAME', ACtx.MyName, '自局の名前', milWarning);
  RequireValue('MYQTH', ACtx.MyQth, '自局の QTH', milWarning);
  RequireValue('MYRIG', ACtx.MyRig, '自局のリグ', milWarning);
  RequireValue('MYANT', ACtx.MyAntenna, '自局のアンテナ', milWarning);
  RequireValue('ANTENNA', ACtx.MyAntenna, '自局のアンテナ', milWarning);
  RequireValue('SERIALIN', ACtx.SerialIn, '受信ナンバー', milWarning);
  RequireValue('XOUT', ACtx.ExchangeOut, '送信コンテストナンバー', milWarning);
  RequireValue('XIN', ACtx.ExchangeIn, '受信コンテストナンバー', milWarning);
  RequireValue('CNTST', ACtx.ContestName, 'コンテスト名', milInfo);
  RequireValue('BAND', ACtx.Band, 'バンド', milWarning);
  RequireValue('MODE', ACtx.Mode, 'モード', milWarning);

  if AExpansion.UsesTag('MYPWR') and (ACtx.MyPowerW <= 0) then
    Note(milWarning, 'MYPWR', '送信出力が未設定のまま送信しようとしています');
  if AExpansion.UsesTag('FREQ') and (ACtx.FreqMHz <= 0) then
    Note(milWarning, 'FREQ', '周波数が未設定のまま送信しようとしています');

  { 送信ナンバーは 1 以上でなければコンテストログとして通らない。 }
  if (AExpansion.UsesTag('#') or AExpansion.UsesTag('SERIAL') or
      AExpansion.UsesTag('#CUT') or AExpansion.UsesTag('SERIALCUT')) and
     (ACtx.SerialOut < 1) then
    Note(milError, '#',
      '送信ナンバーが ' + IntToStr(ACtx.SerialOut) +
      ' です。1 以上である必要があります');

  { --- 4. ログ操作があるのに記録内容が埋まっていない --- }
  if hasLog then
  begin
    if Trim(ACtx.Call) = '' then
      Note(milError, 'LOG',
        '相手局のコールサインが空のままログしようとしています');
    if Trim(ACtx.Mode) = '' then
      Note(milWarning, 'LOG', 'モードが未設定のままログしようとしています');
    if ACtx.FreqMHz <= 0 then
      Note(milWarning, 'LOG', '周波数が未設定のままログしようとしています');
    if Trim(ACtx.RstSent) = '' then
      Note(milWarning, 'LOG', '送信 RST が空のままログしようとしています');
    if Trim(ACtx.RstRcvd) = '' then
      Note(milWarning, 'LOG', '受信 RST が空のままログしようとしています');
  end;
end;

function TMacroExpander.Prepare(const AText: string;
  ACtx: TMacroContext): TMacroExpansion;
begin
  Result := Validate(Expand(AText, ACtx), ACtx);
end;

function TMacroExpander.PrepareNamed(const AName: string;
  ACtx: TMacroContext): TMacroExpansion;
begin
  Result := Validate(ExpandNamed(AName, ACtx), ACtx);
end;

{ ============================ TMacroRunner ============================ }

constructor TMacroRunner.Create(AHost: TMacroHost);
begin
  inherited Create;
  FHost := AHost;
  FAllowWithWarnings := True;
end;

function TMacroRunner.Run(const AExpansion: TMacroExpansion;
  ACtx: TMacroContext; AForce: Boolean): TMacroRunResult;
var
  i: Integer;
  seg: TMacroSegment;
begin
  Result.Executed := False;
  Result.ActionsRun := 0;
  Result.TextSent := 0;
  Result.Logged := False;
  Result.SerialAdvanced := False;
  Result.RefusalReason := '';

  if FHost = nil then
    raise EMacroError.Create('マクロ実行の宿主 (TMacroHost) が設定されていません');
  if ACtx = nil then
    raise EMacroError.Create('実行コンテキストが nil です');

  if not AForce then
  begin
    if AExpansion.HasErrors then
    begin
      Result.RefusalReason := AExpansion.IssueText;
      Exit;
    end;
    if (not FAllowWithWarnings) and AExpansion.HasWarnings then
    begin
      Result.RefusalReason := AExpansion.IssueText;
      Exit;
    end;
  end;

  Result.Executed := True;
  for i := 0 to High(AExpansion.Segments) do
  begin
    seg := AExpansion.Segments[i];
    if seg.Kind = mskText then
    begin
      FHost.SendText(seg.Text);
      Inc(Result.TextSent);
      Continue;
    end;

    Inc(Result.ActionsRun);
    case seg.Action of
      makTransmit:  FHost.StartTransmit;
      makReceive:   FHost.StopTransmit;
      makAbortTx:   FHost.AbortTransmit;
      makClearRx:   FHost.ClearRxWindow;
      makClearTx:   FHost.ClearTxWindow;
      makSetMode:   FHost.SetMode(seg.Arg);
      makSetFreq:   FHost.SetFreqMHz(seg.ArgNum);
      makWait:      FHost.Wait(seg.ArgNum);
      makLog:
        begin
          { 送信ナンバーが進むのはここだけ。ログが成功しなければ
            進めない ― 番号を飛ばすとコンテストのログ照合で減点される。 }
          if FHost.LogCurrentQso then
          begin
            Result.Logged := True;
            ACtx.CommitSerial;
            Result.SerialAdvanced := True;
          end;
        end;
      makIncSerial:
        begin
          ACtx.SerialOut := ACtx.SerialOut + 1;
          Result.SerialAdvanced := True;
        end;
      makDecSerial:
        { 1 未満にはしない (コンテストナンバーは 1 始まり)。 }
        if ACtx.SerialOut > 1 then
          ACtx.SerialOut := ACtx.SerialOut - 1;
    end;
  end;
end;

initialization
  { 日本語のマクロ名・注記を JSON へ往復させるため。
    Unix では DefaultSystemCodePage が 0 のことがあり、これを
    設定しないと UTF-8 文字列が '?' に落ちる (9-2 と同じ不具合)。 }
  SetMultiByteConversionCodePage(CP_UTF8);

end.
