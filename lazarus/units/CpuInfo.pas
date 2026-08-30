{ ============================================================================
  CpuInfo.pas

  Architecture & Requirements Baseline v1.1 §4 X-03 / Phase 1 の
  「CPU capability detection」と、その先の「Resource scaling」の材料。

  なぜ TThread.ProcessorCount を使わないのか
  ----------------------------------------------------------------------------
  使えないからである。この環境で実測するとこうなる。

      TThread.ProcessorCount        = 1
      /proc/cpuinfo の processor 行 = 4
      /proc/self/status の Cpus_allowed_list = 0-3  (= 4)
      nproc                         = 4

  1 を信じて「1 コアしか無い」と判断すると、Phase 1 の完了条件
  「コア数に応じて処理がスケールする」が最初から成立しない。しかも
  誤りだと気づけない ── 動くには動くからである。

  FPC 3.2.2 の RTL は sysconf も sched_getaffinity のラッパーも公開して
  いないので、/proc から読む。生のシステムコールを叩くより素直で、
  読めば何をしているか分かる。

  何を「使えるコア数」と呼ぶか
  ----------------------------------------------------------------------------
  三つの数があり、意味が違う。

  | 数                | 意味                                    |
  |-------------------|-----------------------------------------|
  | 論理プロセッサ数  | 機械に載っている数                      |
  | 実行許可数        | この **プロセス** が乗ってよい数 (affinity) |
  | cgroup の割り当て | この **コンテナ** が使ってよい CPU 時間 |

  資源配分に使うべきは機械の数ではなく、後ろ 2 つの小さい方である。
  コンテナで 0.5 コアしか与えられていないのに 4 本のワーカーを起こせば、
  互いに待ち合うだけで遅くなる。ここを取り違えると、性能改善のつもりが
  性能劣化になり、しかも「並列化したのに速くならない」という
  分かりにくい形で出る。
  ============================================================================ }
unit CpuInfo;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils;

type
  TCpuInfo = record
    { 機械に見えている論理プロセッサ数。 }
    LogicalProcessors: Integer;
    { このプロセスが実行を許されている数 (affinity)。 }
    AllowedProcessors: Integer;
    { cgroup の CPU 割り当て [コア数]。0 = 制限なし。
      0.5 のような小数になりうるので Double。 }
    CgroupQuota: Double;
    { 資源配分に使う数。上の三つから決める。必ず 1 以上。 }
    EffectiveProcessors: Integer;
    { どこから得た値かを残す。数だけ見ても妥当か判断できない。 }
    Source: string;
    function Describe: string;
  end;

{ 一度だけ検出し、以後は同じ値を返す。/proc を毎回読まないため。 }
function GetCpuInfo: TCpuInfo;
{ 検出をやり直す (試験用、または affinity が変わったとき)。 }
function RefreshCpuInfo: TCpuInfo;

{ 資源配分に使う数。GetCpuInfo.EffectiveProcessors と同じ。 }
function EffectiveProcessorCount: Integer;

{ --- 個別の検出 (試験から直接呼べるように公開する) --- }
function DetectLogicalProcessors: Integer;
function DetectAllowedProcessors: Integer;
{ 0 = 制限なし。 }
function DetectCgroupQuota: Double;

{ '0-3,8,10-11' のような一覧を数える。 }
function CountCpuList(const AList: string): Integer;

implementation

var
  GCached: TCpuInfo;
  GHasCache: Boolean = False;

function TCpuInfo.Describe: string;
begin
  Result := Format('論理 %d / 実行許可 %d', [LogicalProcessors, AllowedProcessors]);
  if CgroupQuota > 0 then
    Result := Result + Format(' / cgroup %.2f コア', [CgroupQuota]);
  Result := Result + Format(' → 資源配分に使う数 %d (%s)',
    [EffectiveProcessors, Source]);
end;

function ReadTextFileSafe(const AFileName: string; out AText: string): Boolean;
{ /proc のファイルはサイズが 0 と報告され、しかも **1 回の read() で
  読み切れるとは限らない**。実測では /proc/cpuinfo 4868 バイトに対し
  1 回目の read() が 3651 バイトしか返し、4 個あるはずの processor 行が
  3 個に見えていた (= コア数を 1 つ少なく数えていた)。

  返らなくなるまで繰り返し読む。ファイルサイズに頼らない。 }
const
  CHUNK = 8192;
  MAX_TOTAL = 4 * 1024 * 1024;   { 壊れた /proc で無限に確保しないための上限 }
var
  fs: TFileStream;
  n, total: Integer;
begin
  AText := '';
  Result := False;
  if not FileExists(AFileName) then Exit;
  try
    fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
    try
      total := 0;
      repeat
        if total + CHUNK > MAX_TOTAL then Break;
        SetLength(AText, total + CHUNK);
        n := fs.Read(AText[total + 1], CHUNK);
        if n > 0 then
          Inc(total, n);
      until n <= 0;
      SetLength(AText, total);
      Result := total > 0;
    finally
      fs.Free;
    end;
  except
    { 読めないのは異常ではない (cgroup が無い環境など)。 }
    AText := '';
    Result := False;
  end;
end;

function CountCpuList(const AList: string): Integer;
{ '0-3,8,10-11' → 4 + 1 + 2 = 7 }
var
  parts: TStringArray;
  i, dash, lo, hi: Integer;
  seg: string;
begin
  Result := 0;
  parts := Trim(AList).Split([',']);
  for i := 0 to High(parts) do
  begin
    seg := Trim(parts[i]);
    if seg = '' then Continue;
    dash := Pos('-', seg);
    if dash > 0 then
    begin
      if not TryStrToInt(Trim(Copy(seg, 1, dash - 1)), lo) then Continue;
      if not TryStrToInt(Trim(Copy(seg, dash + 1, MaxInt)), hi) then Continue;
      if hi >= lo then
        Inc(Result, hi - lo + 1);
    end
    else if TryStrToInt(seg, lo) then
      Inc(Result);
  end;
end;

function DetectLogicalProcessors: Integer;
var
  txt: string;
  sl: TStringList;
  i: Integer;
begin
  Result := 0;
  {$IFDEF LINUX}
  if ReadTextFileSafe('/proc/cpuinfo', txt) then
  begin
    sl := TStringList.Create;
    try
      sl.Text := txt;
      for i := 0 to sl.Count - 1 do
        if (Pos('processor', LowerCase(sl[i])) = 1) and (Pos(':', sl[i]) > 0) then
          Inc(Result);
    finally
      sl.Free;
    end;
  end;
  {$ENDIF}
  if Result <= 0 then
    Result := 1;
end;

function DetectAllowedProcessors: Integer;
var
  txt, line: string;
  sl: TStringList;
  i, p: Integer;
begin
  Result := 0;
  {$IFDEF LINUX}
  if ReadTextFileSafe('/proc/self/status', txt) then
  begin
    sl := TStringList.Create;
    try
      sl.Text := txt;
      for i := 0 to sl.Count - 1 do
      begin
        line := sl[i];
        if Pos('Cpus_allowed_list:', line) = 1 then
        begin
          p := Pos(':', line);
          Result := CountCpuList(Copy(line, p + 1, MaxInt));
          Break;
        end;
      end;
    finally
      sl.Free;
    end;
  end;
  {$ENDIF}
  if Result <= 0 then
    Result := DetectLogicalProcessors;
end;

function DetectCgroupQuota: Double;
var
  txt, q, p: string;
  sp: Integer;
  quota, period: Int64;
begin
  Result := 0;   { 0 = 制限なし }
  {$IFDEF LINUX}
  { --- cgroup v2: '/sys/fs/cgroup/cpu.max' が "quota period" か "max period" --- }
  if ReadTextFileSafe('/sys/fs/cgroup/cpu.max', txt) then
  begin
    txt := Trim(txt);
    sp := Pos(' ', txt);
    if sp > 0 then
    begin
      q := Trim(Copy(txt, 1, sp - 1));
      p := Trim(Copy(txt, sp + 1, MaxInt));
      if SameText(q, 'max') then Exit(0);
      if TryStrToInt64(q, quota) and TryStrToInt64(p, period) and
         (period > 0) and (quota > 0) then
        Exit(quota / period);
    end;
    Exit(0);
  end;

  { --- cgroup v1: quota と period が別ファイル。quota = -1 は制限なし --- }
  if ReadTextFileSafe('/sys/fs/cgroup/cpu/cpu.cfs_quota_us', txt) then
  begin
    if not TryStrToInt64(Trim(txt), quota) then Exit(0);
    if quota <= 0 then Exit(0);   { -1 = 制限なし }
    if not ReadTextFileSafe('/sys/fs/cgroup/cpu/cpu.cfs_period_us', txt) then
      Exit(0);
    if not TryStrToInt64(Trim(txt), period) then Exit(0);
    if period <= 0 then Exit(0);
    Exit(quota / period);
  end;
  {$ENDIF}
end;

function RefreshCpuInfo: TCpuInfo;
var
  fromQuota: Integer;
begin
  Result.LogicalProcessors := DetectLogicalProcessors;
  Result.AllowedProcessors := DetectAllowedProcessors;
  Result.CgroupQuota := DetectCgroupQuota;

  { 実行許可数を出発点にする。機械の数ではない ── このプロセスが
    乗れない CPU を数えても意味がない。 }
  Result.EffectiveProcessors := Result.AllowedProcessors;
  Result.Source := 'affinity';

  if Result.CgroupQuota > 0 then
  begin
    { 0.5 コアなら 1 本。1.5 コアなら 1 本 (2 本立てても待ち合うだけ)。
      切り捨てるのは、割り当てを超える本数を立てないためである。 }
    fromQuota := Trunc(Result.CgroupQuota);
    if fromQuota < 1 then fromQuota := 1;
    if fromQuota < Result.EffectiveProcessors then
    begin
      Result.EffectiveProcessors := fromQuota;
      Result.Source := 'cgroup quota';
    end;
  end;

  if Result.EffectiveProcessors < 1 then
  begin
    Result.EffectiveProcessors := 1;
    Result.Source := 'fallback';
  end;

  GCached := Result;
  GHasCache := True;
end;

function GetCpuInfo: TCpuInfo;
begin
  if not GHasCache then
    Exit(RefreshCpuInfo);
  Result := GCached;
end;

function EffectiveProcessorCount: Integer;
begin
  Result := GetCpuInfo.EffectiveProcessors;
end;

end.
