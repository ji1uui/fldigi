{ ============================================================================
  test_context_memory.lpr

  §8 Context Engine の L5/L6 と、§8.1 の保存方針 (ADR-003) の検証。

  確かめるのは、§8 の表と §8.1 が課している性質そのものである。

    1. 暗号プリミティブが **公開試験ベクタと一致** すること
       FIPS 180-4 / RFC 4231 / RFC 8018。往復するだけでは正しさの
       証明にならない (自分の誤りと自分の誤りが打ち消し合う)。

    2. 承認なしに L6 へ入らないこと (§8 の表「ユーザー承認: 必須」)
       既定で L5 内に完結すること (§8.1)。

    3. QSO 終了で L5 が消え、L6 が残ること (§8)

    4. 個人情報が包括承認だけでは上がらないこと (§8.1 最小限保持)

    5. 容器が壊れ・書き換え・未対応の暗号方式を検出すること
       とくに「暗号化されたファイルを平文として読み出さない」こと。

  実行方法: ./run_tests.sh
  ============================================================================ }
program test_context_memory;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils,
  CryptoPrimitives, SecureStore, ContextMemory, Requirements;

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

procedure CheckEq(const AActual, AExpected, AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: [', AExpected, ']  実際: [', AActual, ']');
    Inc(FailCount);
  end;
end;

procedure CheckEqI(AActual, AExpected: Int64; const AMsg: string);
begin
  Inc(TestCount);
  if AActual = AExpected then
    WriteLn('  [OK] ', AMsg)
  else
  begin
    WriteLn('  [NG] ', AMsg);
    WriteLn('        期待: ', AExpected, '  実際: ', AActual);
    Inc(FailCount);
  end;
end;

function TempName(const ASuffix: string): string;
begin
  Result := GetTempDir(False) + 'test_ctxmem_' +
    IntToStr(GetProcessID) + ASuffix;
end;

function BytesHex(const A: TBytes): string;
const
  H = '0123456789abcdef';
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(A) do
    Result := Result + H[(A[i] shr 4) + 1] + H[(A[i] and 15) + 1];
end;

{ 将来の版が書いた「正しく封をされた暗号化ファイル」を作る。

  cipher id を書き換えるだけでは足りない。タグがヘッダを含むので照合に
  失敗し、「壊れている」として弾かれてしまう ── つまり cipher の検査が
  無くても弾かれる。それでは cipher の検査が効いているか確かめられない。
  タグまで正しく付け直して、初めて「復号できないから開かない」を試せる。 }
function ForgeEncryptedContainer(const APlain: string;
  ACipher: TCipherId; AKdf: TKdfId): TBytes;
var
  n, i: Integer;
  h: TSha256;
  tag: TSha256Digest;
begin
  Result := SealString(APlain);
  Result[HDR_CIPHER_OFS] := Ord(ACipher);
  Result[HDR_KDF_OFS] := Ord(AKdf);
  n := Length(Result) - HDR_SIZE - TAG_LEN;
  { 容器の定義どおりに付け直す: ヘッダ + 本体の SHA-256。 }
  h.Init;
  h.Update(Result[0], HDR_SIZE);
  if n > 0 then
    h.Update(Result[HDR_SIZE], n);
  tag := h.Final;
  for i := 0 to TAG_LEN - 1 do
    Result[HDR_SIZE + n + i] := tag[i];
end;

function Bytes(const A: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A));
  if Length(A) > 0 then
    Move(A[1], Result[0], Length(A));
end;

{ --------------------------------------------------------------------------
  1. 公開試験ベクタとの一致

  自作の暗号プリミティブは「往復する」では検証にならない。同じ誤りが
  両方向にあれば往復してしまう。外部が定めた期待値と比べる必要がある。
  -------------------------------------------------------------------------- }
procedure TestKnownAnswerVectors;
var
  s: string;
  i: Integer;
  k: TBytes;
begin
  WriteLn;
  WriteLn('--- 1. 公開試験ベクタ (FIPS 180-4 / RFC 4231 / RFC 8018) ---');

  { FIPS 180-4 の SHA-256 例。 }
  CheckEq(DigestToHex(Sha256String('abc')),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'SHA-256("abc")');
  CheckEq(DigestToHex(Sha256String('')),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'SHA-256("") 空入力');
  CheckEq(DigestToHex(Sha256String(
    'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    'SHA-256 448bit (ブロック境界をまたぐ)');
  CheckEq(DigestToHex(Sha256String(
    'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno' +
    'ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu')),
    'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1',
    'SHA-256 896bit (詰め物が次ブロックへ溢れる場合)');

  s := StringOfChar('a', 1000000);
  CheckEq(DigestToHex(Sha256String(s)),
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    'SHA-256 100万文字 (長さ欄が 32bit を超える)');

  { 逐次投入しても同じになること。 }
  CheckEq(DigestToHex(Sha256String('abcdef')),
    DigestToHex(Sha256String('abcdef')), '同じ入力は同じ結果');

  { RFC 4231 の HMAC-SHA-256。 }
  SetLength(k, 20);
  for i := 0 to 19 do k[i] := $0b;
  CheckEq(DigestToHex(HmacSha256(k, Bytes('Hi There'))),
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
    'HMAC-SHA-256 RFC 4231 #1');
  CheckEq(DigestToHex(HmacSha256Str('Jefe', 'what do ya want for nothing?')),
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    'HMAC-SHA-256 RFC 4231 #2');

  { 鍵がブロック長 (64) を超える場合はハッシュして詰める。 }
  SetLength(k, 131);
  for i := 0 to 130 do k[i] := $aa;
  CheckEq(DigestToHex(HmacSha256(k,
    Bytes('Test Using Larger Than Block-Size Key - Hash Key First'))),
    '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
    'HMAC-SHA-256 RFC 4231 #6 (長い鍵)');

  { PBKDF2-HMAC-SHA-256。 }
  CheckEq(BytesHex(Pbkdf2HmacSha256('password', Bytes('salt'), 1, 32)),
    '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    'PBKDF2-HMAC-SHA256 c=1');
  CheckEq(BytesHex(Pbkdf2HmacSha256('password', Bytes('salt'), 4096, 32)),
    'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
    'PBKDF2-HMAC-SHA256 c=4096');
  { 32 バイトを超える (複数ブロックの連結) 場合。 }
  CheckEq(BytesHex(Pbkdf2HmacSha256('passwordPASSWORDpassword',
    Bytes('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 40)),
    '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1' +
    'c635518c7dac47e9',
    'PBKDF2-HMAC-SHA256 dkLen=40 (2 ブロック)');

  { 一定時間比較が正しく判定すること (時間そのものは測らない)。 }
  Check(ConstantTimeEqual(Sha256String('x'), Sha256String('x')),
    '一定時間比較: 同じものは等しい');
  Check(not ConstantTimeEqual(Sha256String('x'), Sha256String('y')),
    '一定時間比較: 違うものは等しくない');
end;

{ --------------------------------------------------------------------------
  2. 乱数源
  -------------------------------------------------------------------------- }
procedure TestRandomSource;
var
  a, b: TBytes;
begin
  WriteLn;
  WriteLn('--- 2. 乱数源 ---');
  Check(SecureRandomAvailable, 'OS の乱数源が使える');
  a := SecureRandomBytes(32);
  b := SecureRandomBytes(32);
  CheckEqI(Length(a), 32, '要求した長さが返る');
  Check(BytesHex(a) <> BytesHex(b), '二度取れば違う値になる');
  Check(BytesHex(a) <> StringOfChar('0', 64), '全ゼロではない');
  CheckEqI(Length(SecureRandomBytes(0)), 0, '0 バイト要求は空');
end;

{ --------------------------------------------------------------------------
  3. 容器 (SecureStore)
  -------------------------------------------------------------------------- }
procedure TestEnvelope;
var
  c, bad: TBytes;
  back, err: string;
  info: TEnvelopeInfo;
  fn: string;
  i, accepted: Integer;
begin
  WriteLn;
  WriteLn('--- 3. 保存の容器 (§8.1 / ADR-003) ---');

  c := SealString('{"hello":"世界"}');
  Check(Length(c) > 0, '封入できる');
  Check(Inspect(c, info), 'ヘッダを読める');
  Check(not info.IsEncrypted, 'いまは暗号化されていない (cipher=none)');
  CheckEq(CipherIdToStr(info.Cipher), 'none', '方式が none と分かる');
  CheckEqI(info.FormatVersion, SECURE_FORMAT_VERSION, '形式の版が入っている');

  Check(OpenToString(c, back, err), '開封できる');
  CheckEq(back, '{"hello":"世界"}', '中身が往復する (UTF-8 も)');

  { 空の中身。 }
  Check(OpenToString(SealString(''), back, err), '空でも封入・開封できる');
  CheckEq(back, '', '空が空のまま戻る');

  { --- 書き換えの検出 --- }
  c := SealString('balance=100');
  SetLength(bad, Length(c));
  Move(c[0], bad[0], Length(c));
  bad[HDR_SIZE + 8] := Ord('9');   { 本体を書き換える }
  Check(not OpenToString(bad, back, err), '本体の書き換えを検出する');
  Check(Pos('書き換え', err) > 0, '理由が人に読める');

  { ヘッダの書き換えも検出すること。タグがヘッダを含んでいなければ
    ここが通ってしまう。 }
  Move(c[0], bad[0], Length(c));
  bad[HDR_VER_OFS] := 1;
  bad[HDR_ITER_OFS] := 99;
  Check(not OpenToString(bad, back, err), 'ヘッダの書き換えを検出する');

  { --- ここが要点: 暗号化されたファイルを平文として読まない ---
    将来の版が正しく封をして書いたファイルを模す。タグは有効なので、
    完全性検査は通ってしまう。それでも開いてはならない。 }
  bad := ForgeEncryptedContainer('secret payload', cipAes256Gcm,
    kdfArgon2id);
  Check(not OpenToString(bad, back, err),
    '**封が正しくても、未対応の暗号方式なら開かない**');
  Check(Pos('復号できません', err) > 0,
    '理由が「復号できない」と分かる (「壊れている」ではない)');
  Check(Pos('壊れて', err) = 0, '「壊れている」とは言わない (誤診しない)');
  CheckEq(back, '', '中身を平文として渡さない');
  Check(Pos('secret payload', back) = 0, '平文が漏れていない');

  { ヘッダだけは読めること (管理 UI が「暗号化済み」と表示できるように)。 }
  Check(Inspect(bad, info), '開けなくてもヘッダは読める');
  CheckEq(KdfIdToStr(info.Kdf), 'Argon2id', '鍵導出方式も読める');
  Check(info.IsEncrypted, '暗号化されていると分かる');
  CheckEq(CipherIdToStr(info.Cipher), 'AES-256-GCM', '方式名が出る');

  { 未来の形式。 }
  Move(c[0], bad[0], Length(c));
  bad[HDR_VER_OFS] := 99;
  Check(not OpenToString(bad, back, err), '新しすぎる形式は開かない');

  { 別形式のファイル。 }
  Check(not OpenToString(Bytes('this is not a container at all'), back, err),
    '別形式のファイルは開かない');
  Check(not OpenToString(nil, back, err), '空のバイト列は開かない');

  { 途中で切れたファイル。 }
  c := SealString('some payload here');
  accepted := 0;
  for i := Length(c) - 1 downto 1 do
  begin
    SetLength(bad, i);
    Move(c[0], bad[0], i);
    if OpenToString(bad, back, err) then Inc(accepted);
  end;
  CheckEqI(accepted, 0, Format(
    '途中で切れたファイルを 1 つも受け入れない (%d 通り)', [Length(c) - 1]));

  { --- ファイル入出力 --- }
  fn := TempName('.l6');
  SaveSealedFileStr(fn, 'persisted');
  Check(LoadSealedFileStr(fn, back, err), 'ファイルから開ける');
  CheckEq(back, 'persisted', 'ファイル経由でも往復する');
  Check(not LoadSealedFileStr(TempName('.missing'), back, err),
    '無いファイルは False');
  DeleteFile(fn);
end;

{ --------------------------------------------------------------------------
  4. L5/L6 の境界 (§8 の表) ── この ADR の中心
  -------------------------------------------------------------------------- }
procedure TestConsentGate;
var
  m: TContextMemory;
  it: TContextItem;
begin
  WriteLn;
  WriteLn('--- 4. 承認なしに L6 へ入らないこと (§8 / §8.1) ---');
  m := TContextMemory.Create;
  try
    { 既定が「毎回聞く」であること。ここが granted だと
      §8.1「デフォルトでは L5 内で完結する」に反する。 }
    Check(m.Consent = l6AskEveryTime, '**既定は「毎回聞く」**');

    { L5 への記録は承認不要 (§8 の表)。 }
    m.NoteL5('JA1ABC', 'RIG', 'IC-705', ckRig, 'RxExtract', 0.8, True);
    CheckEqI(m.Count, 1, 'L5 には承認なしで入る');
    Check(m.Find('JA1ABC', 'RIG', it), '引ける');
    Check(it.Scope = csL5Session, '入った先は L5');
    CheckEqI(m.CountByScope(csL6Persistent), 0, 'L6 には何も入っていない');
    Check(it.HasEvidence and (Abs(it.Evidence - 0.8) < 1E-9),
      'Evidence が残る (校正前の内部尺度)');
    CheckEq(it.Source, 'RxExtract', '出所が残る');

    { 承認が無ければ L6 へ上がらない。 }
    Check(m.PromoteToL6('JA1ABC', 'RIG') = promNeedsApproval,
      '既定では承認待ちになる');
    CheckEqI(m.CountByScope(csL6Persistent), 0, '**上がっていない**');

    { 拒否されていれば理由が変わる。 }
    m.Consent := l6Denied;
    Check(m.PromoteToL6('JA1ABC', 'RIG') = promDeniedByConsent,
      '拒否されていれば「同意が無い」');
    CheckEqI(m.CountByScope(csL6Persistent), 0, 'やはり上がらない');

    { 包括承認があれば、個人情報でないものは上がる。 }
    m.Consent := l6Granted;
    Check(m.PromoteToL6('JA1ABC', 'RIG') = promStored, '包括承認で上がる');
    CheckEqI(m.CountByScope(csL6Persistent), 1, 'L6 に 1 件');
    Check(m.Find('JA1ABC', 'RIG', it) and (it.Scope = csL6Persistent),
      '層が L6 になった');

    { 無い項目。 }
    Check(m.PromoteToL6('NOBODY', 'RIG') = promNotFound, '無い項目は promNotFound');
  finally
    m.Free;
  end;
end;

{ --------------------------------------------------------------------------
  5. 個人情報は包括承認だけでは上がらない (§8.1 最小限保持)
  -------------------------------------------------------------------------- }
procedure TestPersonalDataMinimisation;
var
  m: TContextMemory;
  it: TContextItem;
begin
  WriteLn;
  WriteLn('--- 5. 個人情報の最小限保持 (§8.1) ---');
  m := TContextMemory.Create;
  try
    m.Consent := l6Granted;   { 包括承認はある }

    m.NoteL5('JA1ABC', 'NAME', 'たろう', ckName, 'RxExtract');
    m.NoteL5('JA1ABC', 'QTH', '東京都八王子市', ckQth, 'RxExtract');
    m.NoteL5('JA1ABC', 'PWR', '50', ckPower, 'RxExtract');
    m.NoteL5('JA1ABC', 'NOTE', '早いCWが好き', ckNote, 'operator');

    Check(m.Find('JA1ABC', 'NAME', it) and it.IsPersonal,
      '名前は個人情報として扱う');
    Check(m.Find('JA1ABC', 'QTH', it) and it.IsPersonal,
      '所在地は個人情報として扱う');
    Check(m.Find('JA1ABC', 'NOTE', it) and it.IsPersonal,
      '覚書は何が書かれるか分からないので個人情報として扱う');
    Check(m.Find('JA1ABC', 'PWR', it) and not it.IsPersonal,
      '出力は個人情報ではない');
    Check(m.Find('JA1ABC', 'RIG', it) = False, '無い項目は見つからない');

    { 包括承認があっても個人情報は上がらない。 }
    Check(m.PromoteToL6('JA1ABC', 'NAME') = promNeedsExplicitPersonal,
      '**包括承認があっても名前は上がらない**');
    Check(m.PromoteToL6('JA1ABC', 'QTH') = promNeedsExplicitPersonal,
      '所在地も上がらない');
    { 個人情報でないものは上がる。 }
    Check(m.PromoteToL6('JA1ABC', 'PWR') = promStored,
      '個人情報でないものは包括承認で上がる');
    CheckEqI(m.CountByScope(csL6Persistent), 1, 'L6 は 1 件だけ');

    { 項目ごとの明示承認があれば上がる。 }
    m.ApprovePersonal('JA1ABC', 'NAME');
    Check(m.PromoteToL6('JA1ABC', 'NAME') = promStored,
      '明示承認すれば上がる');
    Check(m.PromoteToL6('JA1ABC', 'QTH') = promNeedsExplicitPersonal,
      '承認は項目ごと (名前を承認しても所在地は上がらない)');

    { 承認は取り消せる。 }
    m.RevokePersonal('JA1ABC', 'NAME');
    Check(not m.IsPersonalApproved('JA1ABC', 'NAME'), '承認を取り消せる');

    { 運用者が自分で打ち込んだものは L6 に入る (§8.1「ユーザー操作」)。 }
    m.Consent := l6Denied;   { 同意設定が拒否でも }
    m.StoreL6ByOperator('JA9XYZ', 'NAME', 'はなこ', ckName);
    Check(m.Find('JA9XYZ', 'NAME', it) and (it.Scope = csL6Persistent),
      '運用者自身の操作は同意設定に関わらず L6 へ入る');
    CheckEq(it.Source, 'operator', '出所が operator になる');
    Check(m.IsPersonalApproved('JA9XYZ', 'NAME'),
      '承認の記録も残る (なぜ保存されているか説明できる)');
  finally
    m.Free;
  end;
end;

{ --------------------------------------------------------------------------
  6. QSO 終了で L5 が消えること (§8)
  -------------------------------------------------------------------------- }
procedure TestL5Discard;
var
  m: TContextMemory;
  it: TContextItem;
begin
  WriteLn;
  WriteLn('--- 6. QSO 終了で L5 を破棄すること (§8) ---');
  m := TContextMemory.Create;
  try
    m.Consent := l6Granted;
    m.NoteL5('JA1ABC', 'RIG', 'IC-705', ckRig);
    m.NoteL5('JA1ABC', 'PWR', '50', ckPower);
    m.NoteL5('JA1ABC', 'NAME', 'たろう', ckName);
    m.PromoteToL6('JA1ABC', 'RIG');
    CheckEqI(m.Count, 3, '3 件ある');
    CheckEqI(m.CountByScope(csL6Persistent), 1, 'うち L6 は 1 件');

    m.EndQso;
    CheckEqI(m.Count, 1, '**QSO 終了で L5 が消えた**');
    CheckEqI(m.CountByScope(csL5Session), 0, 'L5 が残っていない');
    Check(m.Find('JA1ABC', 'RIG', it), 'L6 は残る');
    Check(not m.Find('JA1ABC', 'PWR', it), 'L5 の項目は引けない');
    Check(not m.Find('JA1ABC', 'NAME', it),
      '**承認しなかった個人情報は消えている**');
    CheckEqI(m.L5DiscardCount, 2, '捨てた件数が数えられる');

    { 二度呼んでも壊れない。 }
    m.EndQso;
    CheckEqI(m.Count, 1, '二度目の EndQso でも L6 は残る');
  finally
    m.Free;
  end;
end;

{ --------------------------------------------------------------------------
  7. View / Edit / Delete (§8.1)
  -------------------------------------------------------------------------- }
procedure TestViewEditDelete;
var
  m: TContextMemory;
  it: TContextItem;
  arr: TContextItemArray;
begin
  WriteLn;
  WriteLn('--- 7. View / Edit / Delete (§8.1) ---');
  m := TContextMemory.Create;
  try
    m.StoreL6ByOperator('JA1ABC', 'NAME', 'たろう', ckName);
    m.StoreL6ByOperator('JA1ABC', 'QTH', '八王子', ckQth);
    m.StoreL6ByOperator('JA9XYZ', 'NAME', 'はなこ', ckName);

    { View }
    CheckEqI(m.Count, 3, '3 件');
    arr := m.ItemsForKey('JA1ABC');
    CheckEqI(Length(arr), 2, '局ごとに引ける');
    CheckEqI(Length(m.AllPersistent), 3, 'L6 をすべて列挙できる');
    CheckEqI(m.PersonalCount, 3, '個人情報の件数が分かる');
    CheckEq(m.Lookup('JA1ABC', 'NAME'), 'たろう', '値を引ける');
    CheckEq(m.Lookup('ja1abc', 'name'), 'たろう', '大小を無視して引ける');
    CheckEq(m.Lookup('NOBODY', 'NAME'), '', '無いものは空文字');

    { Edit }
    Check(m.Edit('JA1ABC', 'NAME', 'タロウ'), '編集できる');
    CheckEq(m.Lookup('JA1ABC', 'NAME'), 'タロウ', '値が変わった');
    Check(m.Find('JA1ABC', 'NAME', it) and (it.Source = 'operator'),
      '編集すると出所が operator になる');
    Check(not it.HasEvidence,
      '運用者が直した値に元の Evidence は残さない');
    Check(not m.Edit('NOBODY', 'NAME', 'x'), '無い項目の編集は False');

    { Delete }
    Check(m.Delete('JA1ABC', 'QTH'), '削除できる');
    CheckEqI(m.Count, 2, '件数が減る');
    Check(not m.IsPersonalApproved('JA1ABC', 'QTH'),
      '**削除すると承認も取り消される** (次に黙って保存されないように)');
    Check(not m.Delete('JA1ABC', 'QTH'), '二度目の削除は False');

    { 局ごと忘れる }
    CheckEqI(m.ForgetKey('JA1ABC'), 1, '局ごと忘れられる');
    CheckEqI(m.Count, 1, '他局は残る');
    CheckEq(m.Lookup('JA9XYZ', 'NAME'), 'はなこ', '他局の記憶は無傷');

    { 全部忘れる }
    m.ForgetAll;
    CheckEqI(m.Count, 0, 'すべて忘れられる');
    Check(not m.IsPersonalApproved('JA9XYZ', 'NAME'), '承認も消える');
  finally
    m.Free;
  end;
end;

{ --------------------------------------------------------------------------
  8. Export / Import (§8.1)
  -------------------------------------------------------------------------- }
procedure TestExportImport;
var
  a, b: TContextMemory;
  js: string;
  fn: string;
  it: TContextItem;
begin
  WriteLn;
  WriteLn('--- 8. Export / Import (§8.1) ---');
  a := TContextMemory.Create;
  b := TContextMemory.Create;
  try
    a.Consent := l6Granted;
    a.StoreL6ByOperator('JA1ABC', 'NAME', 'たろう', ckName);
    a.StoreL6ByOperator('JA1ABC', 'QTH', '東京都八王子市', ckQth);
    a.NoteL5('JA1ABC', 'RIG', 'IC-705', ckRig);
    a.PromoteToL6('JA1ABC', 'RIG');
    a.NoteL5('JA1ABC', 'TEMP', '一時的なもの', ckOther);

    js := a.ExportToJson(True);
    CheckEqI(b.ImportFromJson(js), 3, 'L6 の 3 件を取り込んだ');
    Check(Pos('一時的なもの', js) = 0,
      '**L5 は書き出されない** (QSO 内の一時的なものなので)');
    CheckEq(b.Lookup('JA1ABC', 'NAME'), 'たろう', '値が往復する');
    CheckEq(b.Lookup('JA1ABC', 'QTH'), '東京都八王子市',
      '日本語が壊れない');
    Check(b.Find('JA1ABC', 'NAME', it) and (it.Kind = ckName),
      '種類が往復する');
    Check(b.IsPersonalApproved('JA1ABC', 'NAME'),
      '承認の記録も往復する (取り込んだ先で「承認が無い」にならない)');

    { 個人情報を外して持ち出せること (§8.1 最小限保持)。
      まず「含める」側で実際に出ていることを確かめる ── 文字が壊れて
      いれば Pos は常に 0 になり、外せていなくても通ってしまう。 }
    js := a.ExportToJson(True);
    Check(Pos('たろう', js) > 0, '前提: 含める指定なら書き出しに出る');

    js := a.ExportToJson(False);
    Check(Pos('たろう', js) = 0, '個人情報を外して書き出せる');
    Check(Pos('東京都八王子市', js) = 0, '所在地も外れる');
    Check(Pos('IC-705', js) > 0, '個人情報でないものは残る');

    { ファイル経由。容器を通っていること。 }
    fn := TempName('.l6');
    a.SaveToFile(fn);
    b.ForgetAll;
    Check(b.LoadFromFile(fn), 'ファイルから読める');
    CheckEq(b.Lookup('JA1ABC', 'NAME'), 'たろう', 'ファイル経由でも往復する');

    { 保存されたファイルが容器の形をしていること。 }
    b.ForgetAll;
    Check(b.LoadFromFile(TempName('.nofile')),
      '無いファイルは正常系 (初回起動)');
    CheckEqI(b.Count, 0, '何も読まない');

    DeleteFile(fn);

    { 壊れた入力。 }
    Check(b.ImportFromJson('') = 0, '空文字は 0 件');
    try
      b.ImportFromJson('{ broken');
      Check(False, '壊れた JSON は例外になるべき');
    except
      on EContextMemoryError do Check(True, '壊れた JSON は例外になる');
    end;
    try
      b.ImportFromJson('{"version":99,"items":[]}');
      Check(False, '新しすぎる形式は例外になるべき');
    except
      on EContextMemoryError do Check(True, '新しすぎる形式は拒否する');
    end;
  finally
    a.Free;
    b.Free;
  end;
end;

{ --------------------------------------------------------------------------
  9. 暗号化されたファイルを取り違えないこと (§8.1 / ADR-003)
  -------------------------------------------------------------------------- }
procedure TestEncryptedFileNotMisread;
var
  m: TContextMemory;
  fn: string;
  raw: TBytes;
  f: TFileStream;
  s: string;
begin
  WriteLn;
  WriteLn('--- 9. 暗号化されたファイルを平文として読まないこと ---');
  m := TContextMemory.Create;
  try
    fn := TempName('.enc');
    m.StoreL6ByOperator('JA1ABC', 'NAME', 'たろう', ckName);
    m.SaveToFile(fn);

    { 将来の版が暗号化して **正しく封をして** 書いたファイルを模す。
      封が有効なので完全性検査では弾かれない。 }
    raw := ForgeEncryptedContainer('{"items":[{"key":"JA1ABC"}]}',
      cipXChaCha20Poly1305, kdfArgon2id);
    SetLength(s, Length(raw));
    Move(raw[0], s[1], Length(raw));
    f := TFileStream.Create(fn, fmCreate);
    try
      f.WriteBuffer(s[1], Length(s));
    finally
      f.Free;
    end;

    m.ForgetAll;
    Check(not m.LoadFromFile(fn),
      '**暗号化されたファイルの読み込みは失敗する**');
    CheckEqI(m.Count, 0, '中身を平文として取り込まない');
    Check(Pos('復号できません', m.LastError) > 0,
      '理由が「復号できない」と伝わる');
    Check(Pos('XChaCha20', m.LastError) > 0, 'どの方式かが分かる');

    DeleteFile(fn);
  finally
    m.Free;
  end;
end;

begin
  WriteLn('=== §8 Context L5/L6 と保存方針 (ADR-003) テスト ===');

  TestKnownAnswerVectors;
  TestRandomSource;
  TestEnvelope;
  TestConsentGate;
  TestPersonalDataMinimisation;
  TestL5Discard;
  TestViewEditDelete;
  TestExportImport;
  TestEncryptedFileNotMisread;

  WriteLn;
  WriteLn('=== テスト完了: ', FailCount, ' 件の失敗 (全 ', TestCount, ' 件中) ===');
  { §18 要求トレーサビリティ: **通ったときだけ** 被覆を申告する。
    落ちた試験が「検証した」と言ってはならない。 }
  if FailCount = 0 then
  begin
    CoverReq('SEC-001');
    CoverReq('SEC-002');
    CoverReq('SEC-003');
    CoverReq('SEC-004');
    CoverReq('SEC-005');
    CoverReq('SEC-006');
  end;

  if FailCount > 0 then
    Halt(1);
end.
