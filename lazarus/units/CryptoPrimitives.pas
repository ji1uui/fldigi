{ ============================================================================
  CryptoPrimitives.pas

  Architecture & Requirements Baseline v1.1 §8.1 / ADR-003 のための最小限の
  暗号プリミティブ。SHA-256、HMAC-SHA-256、PBKDF2-HMAC-SHA-256、乱数源。

  なぜ自前で書いたのか / なぜ暗号そのものは書かないのか
  ----------------------------------------------------------------------------
  FPC 3.2.2 が同梱しているのは MD5 / SHA-1 / HMAC-MD5 / HMAC-SHA1 /
  Blowfish / base64 だけである。SHA-256 も AES も PBKDF2 も無い。

  ここで線を引く。

    ハッシュ・MAC・KDF は自前で書いてよい。
      公開された試験ベクタ (FIPS 180-4 / RFC 4231 / RFC 6070) が
      正しさを完全に固定できるためである。実装が合っているかどうかを
      「合っている」と断言できる。

    ブロック暗号・AEAD は自前で書かない。
      試験ベクタが通ることと安全であることが別だからである。
      サイドチャネル、モードの誤用、nonce の再利用は、往復試験では
      いっさい検出されない。「暗号のように見えて暗号でないもの」を
      作る、いちばん典型的なやり方がこれである。

  したがって本ユニットは **秘匿を提供しない**。提供するのは
  完全性検査 (SHA-256) と、暗号が入ったときに必要になる鍵導出
  (PBKDF2) までである。暗号本体の選定は ADR-003 を参照。

  同梱の Blowfish を使わない理由
  ----------------------------------------------------------------------------
  FPC の TBlowFishEncryptStream は 8 バイトごとに独立して暗号化しており、
  連鎖も IV も無い。つまり ECB である (blowfish.pp の Write を参照)。
  同じ平文ブロックが同じ暗号文ブロックになるので、ログのように
  繰り返しの多いデータでは構造がそのまま漏れる。
  加えて Blowfish はブロック長 64 bit で、2026 年に新規採用する選択肢では
  ない。認証も付かない。
  ============================================================================ }
unit CryptoPrimitives;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils;

type
  ECryptoError = class(Exception);

  TSha256Digest = array[0..31] of Byte;

  { 逐次投入できる形。ファイル全体を一度に持たずに済ませるため。 }
  TSha256 = record
  private
    FState: array[0..7] of LongWord;
    FBuf: array[0..63] of Byte;
    FBufLen: Integer;
    FTotalBits: QWord;
    procedure Compress(const ABlock);
  public
    procedure Init;
    procedure Update(const AData; ALen: PtrUInt);
    procedure UpdateStr(const A: string);
    function Final: TSha256Digest;
  end;


function Sha256Buffer(const AData; ALen: PtrUInt): TSha256Digest;
function Sha256String(const A: string): TSha256Digest;
function Sha256Bytes(const A: TBytes): TSha256Digest;
function DigestToHex(const A: TSha256Digest): string;
function HexToDigest(const A: string; out ADigest: TSha256Digest): Boolean;

function HmacSha256(const AKey, AMessage: TBytes): TSha256Digest;
function HmacSha256Str(const AKey, AMessage: string): TSha256Digest;

{ PBKDF2-HMAC-SHA-256 (RFC 8018)。ADR-003 の代替 KDF。
  ADylen は導出する鍵の長さ [バイト]。 }
function Pbkdf2HmacSha256(const APassword: string; const ASalt: TBytes;
  AIterations, ADkLen: Integer): TBytes;

{ 一定時間比較。MAC の照合を早期脱出で書くと、比較の所要時間から
  正解の先頭何バイトが合っていたかが漏れる。 }
function ConstantTimeEqual(const A, B: TSha256Digest): Boolean;
function ConstantTimeEqualBytes(const A, B: TBytes): Boolean;

{ --- 乱数 ---
  OS の CSPRNG から取る。取れなければ **例外にする**。
  ここで Random() に落ちる実装にしてはならない。予測可能な salt や
  nonce は、暗号を入れたときに静かにすべてを無効にする。
  「弱い乱数で動き続ける」より「動かない」ほうが安全である。 }
function SecureRandomBytes(ACount: Integer): TBytes;
{ 乱数源が使えるか (使えない環境を起動時に検出するため)。 }
function SecureRandomAvailable: Boolean;

implementation

{$IFDEF UNIX}
uses
  BaseUnix;
{$ENDIF}

const
  SHA256_K: array[0..63] of LongWord = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5,
    $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3,
    $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc,
    $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7,
    $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13,
    $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3,
    $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5,
    $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208,
    $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

  SHA256_BLOCK = 64;

{ ============================================================================
  ここから SHA-256 の中核。**演算の定義域の宣言**である。

  SHA-256 は仕様として mod 2^32 の加算と、上位ビットを捨てる左シフトで
  定義されている。折り返しは誤りではなく、アルゴリズムそのものである。

  一方このプロジェクトは、アプリ側 (forms/DemoModemApp.lpi) で範囲検査と
  オーバーフロー検査を有効にしている。宣言が無いと、この関数群は
  **アプリのビルド設定では ERangeError で落ちる**。実際に落ちることを
  確認したうえでこの宣言を入れた。

  切っているのはこの範囲だけで、外へは波及しない ($push/$pop)。
  「安全検査を切った」のではなく「ここは 32 bit で回る演算だ」と
  書いてある、と読んでほしい。
  ============================================================================ }
{$push}
{$Q-}  { オーバーフロー検査を切る: 加算が 2^32 で折り返すのが仕様 }
{$R-}  { 範囲検査を切る: 左シフトで上位ビットが落ちるのが仕様 }

function RotR(A: LongWord; N: Byte): LongWord; inline;
begin
  Result := (A shr N) or (A shl (32 - N));
end;

function BE32(A: LongWord): LongWord; inline;
begin
  { SHA-256 はビッグエンディアン。x86 はリトルエンディアンなので入れ替える。
    NtoBE を使わず明示するのは、どちらの向きかを読めば分かるようにするため。 }
  Result := ((A and $000000FF) shl 24) or ((A and $0000FF00) shl 8) or
            ((A and $00FF0000) shr 8) or ((A and $FF000000) shr 24);
end;

procedure TSha256.Init;
begin
  FState[0] := $6a09e667; FState[1] := $bb67ae85;
  FState[2] := $3c6ef372; FState[3] := $a54ff53a;
  FState[4] := $510e527f; FState[5] := $9b05688c;
  FState[6] := $1f83d9ab; FState[7] := $5be0cd19;
  FBufLen := 0;
  FTotalBits := 0;
end;

procedure TSha256.Compress(const ABlock);
var
  w: array[0..63] of LongWord;
  a, b, c, d, e, f, g, h, t1, t2, s0, s1, ch, maj: LongWord;
  i: Integer;
  p: PLongWord;
begin
  p := @ABlock;
  for i := 0 to 15 do
    w[i] := BE32(p[i]);
  for i := 16 to 63 do
  begin
    s0 := RotR(w[i-15], 7) xor RotR(w[i-15], 18) xor (w[i-15] shr 3);
    s1 := RotR(w[i-2], 17) xor RotR(w[i-2], 19) xor (w[i-2] shr 10);
    w[i] := w[i-16] + s0 + w[i-7] + s1;
  end;

  a := FState[0]; b := FState[1]; c := FState[2]; d := FState[3];
  e := FState[4]; f := FState[5]; g := FState[6]; h := FState[7];

  for i := 0 to 63 do
  begin
    s1 := RotR(e, 6) xor RotR(e, 11) xor RotR(e, 25);
    ch := (e and f) xor ((not e) and g);
    t1 := h + s1 + ch + SHA256_K[i] + w[i];
    s0 := RotR(a, 2) xor RotR(a, 13) xor RotR(a, 22);
    maj := (a and b) xor (a and c) xor (b and c);
    t2 := s0 + maj;
    h := g; g := f; f := e; e := d + t1;
    d := c; c := b; b := a; a := t1 + t2;
  end;

  Inc(FState[0], a); Inc(FState[1], b); Inc(FState[2], c); Inc(FState[3], d);
  Inc(FState[4], e); Inc(FState[5], f); Inc(FState[6], g); Inc(FState[7], h);
end;

procedure TSha256.Update(const AData; ALen: PtrUInt);
var
  p: PByte;
  take: PtrUInt;
begin
  if ALen = 0 then Exit;
  p := @AData;
  Inc(FTotalBits, QWord(ALen) * 8);

  { 前回の端数を埋める。 }
  if FBufLen > 0 then
  begin
    take := SHA256_BLOCK - FBufLen;
    if take > ALen then take := ALen;
    Move(p^, FBuf[FBufLen], take);
    Inc(FBufLen, take);
    Inc(p, take);
    Dec(ALen, take);
    if FBufLen = SHA256_BLOCK then
    begin
      Compress(FBuf);
      FBufLen := 0;
    end;
  end;

  while ALen >= SHA256_BLOCK do
  begin
    Compress(p^);
    Inc(p, SHA256_BLOCK);
    Dec(ALen, SHA256_BLOCK);
  end;

  if ALen > 0 then
  begin
    Move(p^, FBuf[0], ALen);
    FBufLen := ALen;
  end;
end;

procedure TSha256.UpdateStr(const A: string);
begin
  if A <> '' then
    Update(A[1], Length(A));
end;

function TSha256.Final: TSha256Digest;
var
  pad: array[0..63] of Byte;
  padLen, i: Integer;
  bits: QWord;
  lenBuf: array[0..7] of Byte;
begin
  { 長さ欄は **詰め物を入れる前の** 長さ。先に確定させてから詰める
    (Update は FTotalBits を増やすので、後から読むと詰め物の分だけ
    ずれる)。 }
  bits := FTotalBits;
  for i := 0 to 7 do
    lenBuf[i] := Byte((bits shr ((7 - i) * 8)) and $FF);

  { 0x80 を置き、長さ 8 バイトがちょうど入る位置 (56 mod 64) まで 0 で埋める。
    padLen は必ず 1 以上なので 0x80 は常に書かれる。 }
  FillChar(pad, SizeOf(pad), 0);
  pad[0] := $80;
  if FBufLen < 56 then
    padLen := 56 - FBufLen
  else
    padLen := 120 - FBufLen;
  Update(pad, padLen);
  Update(lenBuf, 8);

  for i := 0 to 7 do
  begin
    Result[i * 4 + 0] := Byte((FState[i] shr 24) and $FF);
    Result[i * 4 + 1] := Byte((FState[i] shr 16) and $FF);
    Result[i * 4 + 2] := Byte((FState[i] shr 8) and $FF);
    Result[i * 4 + 3] := Byte(FState[i] and $FF);
  end;
end;

{$pop}   { SHA-256 の中核ここまで。以降は通常の検査に戻す。 }

function Sha256Buffer(const AData; ALen: PtrUInt): TSha256Digest;
var
  h: TSha256;
begin
  h.Init;
  h.Update(AData, ALen);
  Result := h.Final;
end;

function Sha256String(const A: string): TSha256Digest;
var
  h: TSha256;
begin
  h.Init;
  h.UpdateStr(A);
  Result := h.Final;
end;

function Sha256Bytes(const A: TBytes): TSha256Digest;
var
  h: TSha256;
begin
  h.Init;
  if Length(A) > 0 then
    h.Update(A[0], Length(A));
  Result := h.Final;
end;

function DigestToHex(const A: TSha256Digest): string;
const
  HEX = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, 64);
  for i := 0 to 31 do
  begin
    Result[i * 2 + 1] := HEX[(A[i] shr 4) + 1];
    Result[i * 2 + 2] := HEX[(A[i] and $0F) + 1];
  end;
end;

function HexToDigest(const A: string; out ADigest: TSha256Digest): Boolean;
var
  i, hi, lo: Integer;

  function Nib(C: Char): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else
      Result := -1;
    end;
  end;

begin
  FillChar(ADigest, SizeOf(ADigest), 0);
  Result := False;
  if Length(A) <> 64 then Exit;
  for i := 0 to 31 do
  begin
    hi := Nib(A[i * 2 + 1]);
    lo := Nib(A[i * 2 + 2]);
    if (hi < 0) or (lo < 0) then Exit;
    ADigest[i] := Byte((hi shl 4) or lo);
  end;
  Result := True;
end;

{ ============================ HMAC-SHA-256 (RFC 2104) ============================ }

function HmacSha256(const AKey, AMessage: TBytes): TSha256Digest;
var
  k0: array[0..SHA256_BLOCK - 1] of Byte;
  ipad, opad: array[0..SHA256_BLOCK - 1] of Byte;
  inner: TSha256Digest;
  h: TSha256;
  i: Integer;
  kd: TSha256Digest;
begin
  FillChar(k0, SizeOf(k0), 0);
  if Length(AKey) > SHA256_BLOCK then
  begin
    { 鍵がブロックより長ければハッシュして詰める。 }
    kd := Sha256Bytes(AKey);
    Move(kd[0], k0[0], SizeOf(kd));
  end
  else if Length(AKey) > 0 then
    Move(AKey[0], k0[0], Length(AKey));

  for i := 0 to SHA256_BLOCK - 1 do
  begin
    ipad[i] := k0[i] xor $36;
    opad[i] := k0[i] xor $5C;
  end;

  h.Init;
  h.Update(ipad, SHA256_BLOCK);
  if Length(AMessage) > 0 then
    h.Update(AMessage[0], Length(AMessage));
  inner := h.Final;

  h.Init;
  h.Update(opad, SHA256_BLOCK);
  h.Update(inner, SizeOf(inner));
  Result := h.Final;
end;

function DigestToBytes(const A: TSha256Digest): TBytes;
begin
  Result := nil;
  SetLength(Result, SizeOf(A));
  Move(A[0], Result[0], SizeOf(A));
end;

function StrToBytes(const A: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A));
  if Length(A) > 0 then
    Move(A[1], Result[0], Length(A));
end;

function HmacSha256Str(const AKey, AMessage: string): TSha256Digest;
begin
  Result := HmacSha256(StrToBytes(AKey), StrToBytes(AMessage));
end;

{ ============================ PBKDF2 (RFC 8018) ============================ }

function Pbkdf2HmacSha256(const APassword: string; const ASalt: TBytes;
  AIterations, ADkLen: Integer): TBytes;
var
  key: TBytes;
  blockInput: TBytes;
  u, t: TSha256Digest;
  i, j, k, blocks, need, ofs: Integer;
begin
  if AIterations < 1 then
    raise ECryptoError.Create('PBKDF2 の反復回数は 1 以上でなければなりません');
  if ADkLen < 1 then
    raise ECryptoError.Create('PBKDF2 の鍵長は 1 以上でなければなりません');

  Result := nil;
  key := StrToBytes(APassword);
  blocks := (ADkLen + 31) div 32;
  SetLength(Result, ADkLen);
  ofs := 0;

  for i := 1 to blocks do
  begin
    { U1 = HMAC(P, S || INT_32_BE(i)) }
    SetLength(blockInput, Length(ASalt) + 4);
    if Length(ASalt) > 0 then
      Move(ASalt[0], blockInput[0], Length(ASalt));
    blockInput[Length(ASalt) + 0] := Byte((i shr 24) and $FF);
    blockInput[Length(ASalt) + 1] := Byte((i shr 16) and $FF);
    blockInput[Length(ASalt) + 2] := Byte((i shr 8) and $FF);
    blockInput[Length(ASalt) + 3] := Byte(i and $FF);

    u := HmacSha256(key, blockInput);
    t := u;
    for j := 2 to AIterations do
    begin
      u := HmacSha256(key, DigestToBytes(u));
      for k := 0 to 31 do
        t[k] := t[k] xor u[k];
    end;

    need := ADkLen - ofs;
    if need > 32 then need := 32;
    Move(t[0], Result[ofs], need);
    Inc(ofs, need);
  end;
end;

{ ============================ 一定時間比較 ============================ }

function ConstantTimeEqual(const A, B: TSha256Digest): Boolean;
var
  i: Integer;
  diff: Byte;
begin
  { 早期脱出しない。所要時間から「先頭何バイトが合っていたか」を
    漏らさないため。 }
  diff := 0;
  for i := 0 to 31 do
    diff := diff or (A[i] xor B[i]);
  Result := diff = 0;
end;

function ConstantTimeEqualBytes(const A, B: TBytes): Boolean;
var
  i: Integer;
  diff: Byte;
begin
  if Length(A) <> Length(B) then Exit(False);
  diff := 0;
  for i := 0 to High(A) do
    diff := diff or (A[i] xor B[i]);
  Result := diff = 0;
end;

{ ============================ 乱数 ============================ }

function SecureRandomBytes(ACount: Integer): TBytes;
{$IFDEF UNIX}
var
  fd: LongInt;
  got, n: Integer;
{$ENDIF}
begin
  Result := nil;
  if ACount <= 0 then Exit;
  SetLength(Result, ACount);

{$IFDEF UNIX}
  fd := FpOpen('/dev/urandom', O_RDONLY);
  if fd < 0 then
    raise ECryptoError.Create(
      '乱数源 (/dev/urandom) を開けません。salt や nonce を安全に' +
      '作れないため処理を中止します。');
  try
    got := 0;
    while got < ACount do
    begin
      n := FpRead(fd, Result[got], ACount - got);
      if n <= 0 then
        raise ECryptoError.Create('乱数源から読み出せません。');
      Inc(got, n);
    end;
  finally
    FpClose(fd);
  end;
{$ELSE}
  { 他のプラットフォームでは OS の CSPRNG を呼ぶ実装を足すこと
    (Windows: BCryptGenRandom / macOS: SecRandomCopyBytes)。
    ここで Random() に落としてはならない。予測可能な salt と nonce は、
    暗号を入れた瞬間に静かにすべてを無効にする。 }
  raise ECryptoError.Create(
    'このプラットフォームの乱数源が未実装です。' +
    '弱い乱数で続行しないため処理を中止します。');
{$ENDIF}
end;

function SecureRandomAvailable: Boolean;
begin
  try
    SecureRandomBytes(1);
    Result := True;
  except
    Result := False;
  end;
end;

end.
