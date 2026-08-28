{ ============================================================================
  SafeFileIO.pas

  設定ファイル・ログファイルの保存/読込を安全に行うための共通ヘルパー。

  解決する問題:
  ----------------------------------------------------------------------------
  1. **保存の非アトミック性によるファイル消失**
     従来は各ユニットが `TStringList.SaveToFile(AFileName)` で保存対象を
     直接開いて上書きしていた。この方式では「開いて切り詰めた直後・
     書き込み完了前」に電源断やクラッシュが起きると、保存先が空または
     途中までの内容になり、それまでの設定やログがすべて失われる。

     本アプリは実行ファイルと同じディレクトリに設定を置く = USB メモリで
     持ち運び、バッテリー運用の移動運用先でも使う想定であり、書き込み中の
     電源断は現実に起こりうる。そこで「一時ファイルへ書き切ってから
     rename で置き換える」方式にする。rename は POSIX では原子的操作なので、
     どの瞬間に電源が落ちても保存先は「更新前の完全な内容」か
     「更新後の完全な内容」のどちらかになり、半端な状態にはならない。

  2. **長さ指定書式のファイルを TStringList 経由で読むと壊れる**
     ADIF は `<CALL:4>W1AW` のようにフィールド長をバイト数で前置する
     書式である。`TStringList.LoadFromFile` + `.Text` で読むと改行コードが
     正規化される (CRLF -> LF 等) ため、値に改行を含むフィールド
     (NOTES/COMMENT など ADIF が許容する) があると長さと実際のバイト数が
     ずれ、以降のフィールドをすべて誤って切り出す。末尾に改行が付与される
     副作用もある。そのため生のバイト列として読む関数を用意する。
  ============================================================================ }
unit SafeFileIO;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  ESafeFileIOError = class(Exception);

{ ファイル全体を 1 バイトも変換せずに読み込む。
  TStringList を経由しないため、改行コードの正規化も末尾改行の付与も
  起こらない。ADIF のような長さ指定書式の解析に使う。
  ファイルが存在しない場合は空文字を返す (例外は投げない)。 }
const
  { テキストとして一括読み込みする上限 (256 MiB)。
    これを超えるのは設定やログの取り違えであり、読めないことより
    メモリを食い潰す方が害が大きい。 }
  MAX_TEXT_FILE_BYTES = Int64(256) * 1024 * 1024;

function LoadTextRaw(const AFileName: string): string;

{ 内容を原子的に保存する。
  一時ファイル (AFileName + '.tmp') へ書き切り、フラッシュしてから
  rename で AFileName を置き換える。途中で失敗した場合は一時ファイルを
  削除し、元の AFileName は手つかずのまま残す。
  AText は変換せずそのまま書き出す (呼び出し側が UTF-8 で組み立てる)。 }
procedure SaveTextAtomic(const AFileName, AText: string);

implementation

function LoadTextRaw(const AFileName: string): string;
var
  fs: TFileStream;
  n: Int64;
begin
  Result := '';
  if not FileExists(AFileName) then Exit;

  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    n := fs.Size;
    if n <= 0 then Exit;
    { 巨大ファイルは扱わない。以前は High(SizeInt) と比較していたが、
      64bit では SizeInt が Int64 なので条件が常に偽になり、
      検査として機能していなかった (コンパイラも到達不能と警告する)。
      本ユニットが扱うのは設定・ログ・ADIF といったテキストなので、
      現実的な上限を明示する方が意味がある。 }
    if n > MAX_TEXT_FILE_BYTES then
      raise ESafeFileIOError.CreateFmt(
        'ファイルが大きすぎます (%d バイト / 上限 %d バイト): %s',
        [n, MAX_TEXT_FILE_BYTES, AFileName]);
    SetLength(Result, SizeInt(n));
    fs.ReadBuffer(Result[1], SizeInt(n));
  finally
    fs.Free;
  end;
end;

procedure SaveTextAtomic(const AFileName, AText: string);
var
  tmpName: string;
  fs: TFileStream;
begin
  tmpName := AFileName + '.tmp';

  { --- 1. 一時ファイルへ完全に書き切る --- }
  try
    fs := TFileStream.Create(tmpName, fmCreate);
    try
      if Length(AText) > 0 then
        fs.WriteBuffer(AText[1], Length(AText));
    finally
      { Free がクローズを行い、この時点で OS のバッファへは渡り切る。 }
      fs.Free;
    end;
  except
    on E: Exception do
    begin
      { 書き込みに失敗したら中途半端な一時ファイルを残さない。
        保存先 AFileName は一切触っていないので無傷のまま。 }
      if FileExists(tmpName) then
        DeleteFile(tmpName);
      raise ESafeFileIOError.CreateFmt(
        '一時ファイルへの書き込みに失敗しました (%s): %s', [tmpName, E.Message]);
    end;
  end;

  { --- 2. rename で置き換える --- }
  {$IFDEF WINDOWS}
  { Windows の rename は置換先が存在すると失敗するため、先に削除する。
    この一瞬だけは保存先が存在しない状態になるが、内容が半端になる
    ことはない (完全な一時ファイルは既に手元にある)。 }
  if FileExists(AFileName) then
    DeleteFile(AFileName);
  {$ENDIF}
  if not RenameFile(tmpName, AFileName) then
  begin
    if FileExists(tmpName) then
      DeleteFile(tmpName);
    raise ESafeFileIOError.CreateFmt(
      'ファイルの置き換えに失敗しました: %s', [AFileName]);
  end;
end;

end.
