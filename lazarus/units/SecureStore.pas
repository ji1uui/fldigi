{ ============================================================================
  SecureStore.pas

  Architecture & Requirements Baseline v1.1 §8.1 の

      「保存形式は将来暗号化を可能にする設計とし、
        暗号化の実装方式は Phase 0 で決定する」

  に対する容れ物。決定そのものは docs/adr/ADR-003-l6-privacy.md。

  何をして、何をしないか
  ----------------------------------------------------------------------------
  する:   容器の形を決める。アルゴリズム識別子・salt・nonce・認証タグの
          場所を確保し、後から暗号を入れても **移行が要らない** ようにする。
          完全性検査 (改竄・破損の検出) を行う。
  しない: 秘匿。いまの実装は cipher = none、つまり平文で保存する。

  「後で暗号化できる設計」を本当に後でできるようにするには
  ----------------------------------------------------------------------------
  この種の約束が破られるのは、たいてい次の形である。

    - 平文のまま素朴に保存し、後から「先頭に鍵情報を足そう」とする。
      既存ファイルが全部読めなくなるので、移行コードが要る。
    - 暗号方式を 1 つ決め打ちで埋め込む。後で変えられない。
    - 暗号化された古いファイルを、新しい版が平文として読んでしまう。

  だから最初から容器を通す。いまは中身が平文でも、容器は同じである。
  そして **知らない cipher id のファイルは開かない**。これが無いと、
  暗号化されたファイルを平文として読み出して見せてしまう ── 
  個人情報を扱う保存先で、いちばんやってはいけない壊れ方である。

  タグは何を守っているか
  ----------------------------------------------------------------------------
  cipher = none のときのタグは **鍵の無い SHA-256 チェックサム** である。
  破損と、気づかない書き換えを検出する。これは秘匿でも認証でもない ──
  誰でも中身を書き換えてタグを付け直せる。そう書いておかないと、
  「タグが付いているから守られている」と誤解される。

  鍵が入ったとき (ADR-003) は、この欄が AEAD の認証タグになる。
  タグはヘッダも含めて計算する。含めないと cipher id を書き換えられて、
  「暗号化済み」を「平文」と偽れてしまう (AEAD でいう AAD にあたる)。
  ============================================================================ }
unit SecureStore;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, CryptoPrimitives, SafeFileIO;

type
  ESecureStoreError = class(Exception);

  { --- 暗号方式の識別子 ---
    数値はファイルに書かれるので **決して振り直さない**。
    追加は末尾に足す。 }
  TCipherId = (
    cipNone = 0,              // 平文。いま唯一実装されているもの
    cipAes256Gcm = 1,         // 予約 (ADR-003 の第一候補)
    cipXChaCha20Poly1305 = 2  // 予約 (ADR-003 の対案)
  );

  TKdfId = (
    kdfNone = 0,
    kdfArgon2id = 1,          // 予約 (ADR-003 の第一候補)
    kdfPbkdf2Sha256 = 2       // 実装済み (CryptoPrimitives)
  );

  { 開かずに読める情報。「この保存先は暗号化されているか」を
    利用者に見せるために要る (§8.1 の管理 UI)。 }
  TEnvelopeInfo = record
    FormatVersion: Integer;
    Cipher: TCipherId;
    Kdf: TKdfId;
    KdfIterations: Integer;
    PayloadLength: Integer;
    function IsEncrypted: Boolean;
    function Describe: string;
  end;

const
  SECURE_MAGIC = 'L6ST';
  SECURE_FORMAT_VERSION = 1;

  { ヘッダの配置。数値も位置も、書いたら変えない。 }
  HDR_MAGIC_OFS   = 0;   HDR_MAGIC_LEN   = 4;
  HDR_VER_OFS     = 4;   HDR_VER_LEN     = 2;
  HDR_CIPHER_OFS  = 6;
  HDR_KDF_OFS     = 7;
  HDR_ITER_OFS    = 8;   HDR_ITER_LEN    = 4;
  HDR_SALT_OFS    = 12;  HDR_SALT_LEN    = 16;
  HDR_NONCE_OFS   = 28;  HDR_NONCE_LEN   = 12;
  HDR_PLEN_OFS    = 40;  HDR_PLEN_LEN    = 4;
  HDR_SIZE        = 44;
  TAG_LEN         = 32;

  { 壊れた入力で無制限に確保しないための上限 (64 MiB)。 }
  MAX_PAYLOAD = 64 * 1024 * 1024;

{ --- 封入 ---
  いまは cipher = none のみ。salt と nonce は将来のために確保するが、
  cipher = none では使わないので 0 で埋める (乱数源が無い環境でも
  平文保存はできるようにするため。乱数が要るのは暗号を入れてからである)。 }
function Seal(const APlaintext: TBytes): TBytes;
function SealString(const APlaintext: string): TBytes;

{ --- 開封 ---
  戻り値: 開けたか。開けなかった理由は AError に入る。
  例外にしないのは、開けないファイルが日常的にありうる (別の版で書かれた、
  破損した) ためで、呼び出し側が利用者に説明できる形にしたい。 }
function Open(const AContainer: TBytes; out APlaintext: TBytes;
  out AError: string): Boolean;
function OpenToString(const AContainer: TBytes; out APlaintext: string;
  out AError: string): Boolean;

{ 中身を開かずにヘッダだけ読む。 }
function Inspect(const AContainer: TBytes; out AInfo: TEnvelopeInfo): Boolean;

{ --- ファイル入出力 ---
  書き込みは SafeFileIO の一時ファイル + rename。 }
procedure SaveSealedFile(const AFileName: string; const APlaintext: TBytes);
procedure SaveSealedFileStr(const AFileName, APlaintext: string);
function LoadSealedFile(const AFileName: string; out APlaintext: TBytes;
  out AError: string): Boolean;
function LoadSealedFileStr(const AFileName: string; out APlaintext: string;
  out AError: string): Boolean;

function CipherIdToStr(A: TCipherId): string;
function KdfIdToStr(A: TKdfId): string;

implementation

function CipherIdToStr(A: TCipherId): string;
begin
  case A of
    cipNone:                 Result := 'none';
    cipAes256Gcm:            Result := 'AES-256-GCM';
    cipXChaCha20Poly1305:    Result := 'XChaCha20-Poly1305';
  else
    Result := Format('unknown(%d)', [Ord(A)]);
  end;
end;

function KdfIdToStr(A: TKdfId): string;
begin
  case A of
    kdfNone:          Result := 'none';
    kdfArgon2id:      Result := 'Argon2id';
    kdfPbkdf2Sha256:  Result := 'PBKDF2-HMAC-SHA256';
  else
    Result := Format('unknown(%d)', [Ord(A)]);
  end;
end;

function TEnvelopeInfo.IsEncrypted: Boolean;
begin
  Result := Cipher <> cipNone;
end;

function TEnvelopeInfo.Describe: string;
begin
  Result := Format('形式 v%d / 暗号 %s / 鍵導出 %s / 本体 %d バイト',
    [FormatVersion, CipherIdToStr(Cipher), KdfIdToStr(Kdf), PayloadLength]);
  if KdfIterations > 0 then
    Result := Result + Format(' / 反復 %d 回', [KdfIterations]);
end;

procedure PutU16(var A: TBytes; AOfs: Integer; AValue: Integer);
begin
  A[AOfs] := Byte(AValue and $FF);
  A[AOfs + 1] := Byte((AValue shr 8) and $FF);
end;

function GetU16(const A: TBytes; AOfs: Integer): Integer;
begin
  Result := A[AOfs] or (A[AOfs + 1] shl 8);
end;

procedure PutU32(var A: TBytes; AOfs: Integer; AValue: LongWord);
var
  i: Integer;
begin
  for i := 0 to 3 do
    A[AOfs + i] := Byte((AValue shr (i * 8)) and $FF);
end;

function GetU32(const A: TBytes; AOfs: Integer): LongWord;
var
  i: Integer;
begin
  Result := 0;
  for i := 3 downto 0 do
    Result := (Result shl 8) or A[AOfs + i];
end;

{ ヘッダと本体をまとめてハッシュする。ヘッダを含めるのが要点 ──
  含めないと cipher id を書き換えられ、「暗号化済み」を「平文」と
  偽れてしまう。 }
function ComputeTag(const AContainer: TBytes; APayloadLen: Integer): TSha256Digest;
var
  h: TSha256;
begin
  h.Init;
  h.Update(AContainer[0], HDR_SIZE);
  if APayloadLen > 0 then
    h.Update(AContainer[HDR_SIZE], APayloadLen);
  Result := h.Final;
end;

function Seal(const APlaintext: TBytes): TBytes;
var
  n, i: Integer;
  tag: TSha256Digest;
begin
  Result := nil;
  n := Length(APlaintext);
  SetLength(Result, HDR_SIZE + n + TAG_LEN);
  FillChar(Result[0], Length(Result), 0);

  for i := 0 to HDR_MAGIC_LEN - 1 do
    Result[HDR_MAGIC_OFS + i] := Byte(SECURE_MAGIC[i + 1]);
  PutU16(Result, HDR_VER_OFS, SECURE_FORMAT_VERSION);
  Result[HDR_CIPHER_OFS] := Ord(cipNone);
  Result[HDR_KDF_OFS] := Ord(kdfNone);
  PutU32(Result, HDR_ITER_OFS, 0);
  { salt と nonce は将来のために場所だけ確保する。cipher = none では
    使わないので 0 のまま。ここで乱数を要求すると、乱数源の無い環境で
    平文保存すらできなくなる ── 乱数が要るのは暗号を入れてからである。 }
  PutU32(Result, HDR_PLEN_OFS, LongWord(n));

  if n > 0 then
    Move(APlaintext[0], Result[HDR_SIZE], n);

  tag := ComputeTag(Result, n);
  Move(tag[0], Result[HDR_SIZE + n], TAG_LEN);
end;

function StrToBytesRaw(const A: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A));
  if Length(A) > 0 then
    Move(A[1], Result[0], Length(A));
end;

function BytesToStrRaw(const A: TBytes): string;
begin
  SetLength(Result, Length(A));
  if Length(A) > 0 then
    Move(A[0], Result[1], Length(A));
end;

function SealString(const APlaintext: string): TBytes;
begin
  Result := Seal(StrToBytesRaw(APlaintext));
end;

function ReadHeader(const AContainer: TBytes; out AInfo: TEnvelopeInfo;
  out AError: string): Boolean;
var
  i: Integer;
begin
  AError := '';
  FillChar(AInfo, SizeOf(AInfo), 0);
  Result := False;

  if Length(AContainer) < HDR_SIZE + TAG_LEN then
  begin
    AError := 'ファイルが短すぎます (容器の体裁になっていません)。';
    Exit;
  end;
  for i := 0 to HDR_MAGIC_LEN - 1 do
    if AContainer[HDR_MAGIC_OFS + i] <> Byte(SECURE_MAGIC[i + 1]) then
    begin
      AError := 'この形式のファイルではありません。';
      Exit;
    end;

  AInfo.FormatVersion := GetU16(AContainer, HDR_VER_OFS);
  AInfo.Cipher := TCipherId(AContainer[HDR_CIPHER_OFS]);
  AInfo.Kdf := TKdfId(AContainer[HDR_KDF_OFS]);
  AInfo.KdfIterations := Integer(GetU32(AContainer, HDR_ITER_OFS));
  AInfo.PayloadLength := Integer(GetU32(AContainer, HDR_PLEN_OFS));
  Result := True;
end;

function Inspect(const AContainer: TBytes; out AInfo: TEnvelopeInfo): Boolean;
var
  err: string;
begin
  Result := ReadHeader(AContainer, AInfo, err);
end;

function Open(const AContainer: TBytes; out APlaintext: TBytes;
  out AError: string): Boolean;
var
  info: TEnvelopeInfo;
  n: Integer;
  want, got: TSha256Digest;
begin
  APlaintext := nil;
  Result := False;
  if not ReadHeader(AContainer, info, AError) then Exit;

  if info.FormatVersion > SECURE_FORMAT_VERSION then
  begin
    AError := Format(
      '保存形式が新しすぎます (ファイル v%d / このプログラム v%d)。' +
      '古い版で開くと内容を失うため中止しました。',
      [info.FormatVersion, SECURE_FORMAT_VERSION]);
    Exit;
  end;

  { --- ここが要点 ---
    知らない・未実装の暗号方式のファイルは **開かない**。
    平文として読み出してしまうと、暗号化された個人情報をそのまま
    表示することになる。 }
  if info.Cipher <> cipNone then
  begin
    AError := Format(
      'この保存先は %s で暗号化されていますが、この版は復号できません。' +
      '内容を平文として読み出すことはしません。',
      [CipherIdToStr(info.Cipher)]);
    Exit;
  end;

  n := info.PayloadLength;
  if (n < 0) or (n > MAX_PAYLOAD) then
  begin
    AError := 'ファイルの長さ欄が壊れています。';
    Exit;
  end;
  if Length(AContainer) <> HDR_SIZE + n + TAG_LEN then
  begin
    AError := 'ファイルの長さが合いません (途中で切れている可能性があります)。';
    Exit;
  end;

  Move(AContainer[HDR_SIZE + n], want[0], TAG_LEN);
  got := ComputeTag(AContainer, n);
  { 一定時間比較。いまは鍵無しのチェックサムなので時間差から漏れるものは
    無いが、鍵が入ったときにここを直し忘れないよう最初からこうしておく。 }
  if not ConstantTimeEqual(want, got) then
  begin
    AError := '内容が壊れているか、書き換えられています (照合値が一致しません)。';
    Exit;
  end;

  SetLength(APlaintext, n);
  if n > 0 then
    Move(AContainer[HDR_SIZE], APlaintext[0], n);
  Result := True;
end;

function OpenToString(const AContainer: TBytes; out APlaintext: string;
  out AError: string): Boolean;
var
  b: TBytes;
begin
  APlaintext := '';
  Result := Open(AContainer, b, AError);
  if Result then
    APlaintext := BytesToStrRaw(b);
end;

procedure SaveSealedFile(const AFileName: string; const APlaintext: TBytes);
begin
  SaveTextAtomic(AFileName, BytesToStrRaw(Seal(APlaintext)));
end;

procedure SaveSealedFileStr(const AFileName, APlaintext: string);
begin
  SaveSealedFile(AFileName, StrToBytesRaw(APlaintext));
end;

function LoadSealedFile(const AFileName: string; out APlaintext: TBytes;
  out AError: string): Boolean;
begin
  APlaintext := nil;
  AError := '';
  if not FileExists(AFileName) then
  begin
    AError := 'ファイルがありません。';
    Exit(False);
  end;
  Result := Open(StrToBytesRaw(LoadTextRaw(AFileName)), APlaintext, AError);
end;

function LoadSealedFileStr(const AFileName: string; out APlaintext: string;
  out AError: string): Boolean;
var
  b: TBytes;
begin
  APlaintext := '';
  Result := LoadSealedFile(AFileName, b, AError);
  if Result then
    APlaintext := BytesToStrRaw(b);
end;

end.
