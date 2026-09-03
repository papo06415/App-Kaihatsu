# ちょっと賢い猫 — カレンダー層

カレンダーの予定に対して「何時に出発すべきか」を計算するための基盤。
このリポジトリに入っているのは **カレンダー層だけ** で、移動時間の取得（MapKit）、天気の取得
（WeatherKit）、通知、UI は後続フェーズ。

## モジュール構成

```
Package.swift
Sources/
  CatCore/                   ← Apple 非依存。Linux でテストできる
    Models/                    EventKey / CalendarEvent / EventSnapshot / DailySlots / …
    Protocols/                 CalendarSource / GeocodingService / FileStore
    Logic/                     CompletionEvaluator / ChangeDetector / SlotConfirmer /
                               ConflictDetector / LocationResolver
    Persistence/               Repository / RetentionPolicy
    CalendarLayer.swift        全体の統合（refreshOnLaunch）
  CatPlatform/               ← Apple 依存。全ソースが #if canImport(EventKit) で囲まれている
    EventKitCalendarSource.swift
    AppleGeocodingService.swift
    ApplicationSupportFileStore.swift
Tests/
  CatCoreTests/              CatCore にのみ依存する（CatPlatform には依存させない）
  Mocks/                     MockCalendarSource / MockGeocodingService / InMemoryFileStore
```

### なぜ分けているのか

EventKit・MapKit・CoreLocation は Apple プラットフォームでしかコンパイルできない。これらを
直接呼ぶコードにロジックが混ざっていると、検証手段が「Mac 上で実機/シミュレータを動かす」しか
なくなる。枠の確定や編集回数のカウントのような**微妙な条件分岐の塊**を、その方法だけで担保するのは
現実的ではない。

そこで Apple が要るものは3つのプロトコル（`CalendarSource` / `GeocodingService` / `FileStore`）に
押し出し、CatCore の側はそのプロトコルにしか触らないようにしてある。結果として：

- CatCore は `import Foundation` だけで閉じており、Linux 上で `swift test` が走る。
- テストは実機のカレンダーやネットワークに依存せず、現在時刻もカレンダー（タイムゾーン）も
  引数で固定できる。
- CatPlatform は「EventKit の型を CatCore の型に詰め替えるだけ」の薄い層になり、
  ロジックを持たない。

`FileStore` まで抽象化しているのは、保存先ディレクトリの取得自体が Apple 依存だから
（Application Support は Linux に存在しない）。

## Linux でテストを走らせる

Swift 5.9 以上のツールチェーンがあれば、それだけで動く。

```bash
swift build
swift test
```

このリポジトリは Swift 6.0.3（Ubuntu 24.04, x86_64）で検証済み。

```
Executed 88 tests, with 0 failures
```

`CatPlatform` は Linux 上では `#if canImport(EventKit)` が偽になるため中身が空になる。
ビルドは通るが、**Linux 上では CatPlatform のコードは一行もコンパイルされない**
（後述の「実装できなかった項目」を参照）。

テストの対象内訳:

| ファイル | 件数 | 内容 |
| --- | --- | --- |
| `CompletionEvaluatorTests` | 5 | 開始時刻の境界、終日予定 |
| `ChangeDetectorTests` | 11 | 編集回数、完了後の凍結、削除、繰り返し予定 |
| `LocationResolverTests` | 11 | キャッシュ規則、逐次実行、枠の打ち切り |
| `MockGeocodingServiceTests` | 1 | 「並行実行を検出できる」ことの確認 |
| `SlotConfirmerTests` | 19 | 第1/第2段階、枠の解放、日跨ぎ、Premium |
| `ConflictDetectorTests` | 8 | 同時刻/部分重複/境界接触/終日 |
| `RepositoryTests` | 11 | 往復、壊れた JSON、書き込み失敗 |
| `RetentionPolicyTests` | 6 | 14日 / 3日 / 24時間 |
| `CalendarLayerTests` | 16 | 統合（権限・枠・日跨ぎ・再起動・期限切れ削除） |

## Mac 上で追加が必要なこと

### 1. Info.plist

カレンダーのフルアクセスを要求するため、アプリターゲットの Info.plist に以下が必須。
これが無いと `requestFullAccessToEvents()` を呼んだ時点でクラッシュする。

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>予定の場所と時刻から、何時に出発すればいいかを計算するためにカレンダーを読みます。</string>
```

iOS 16 以前も対象にする場合は `NSCalendarsUsageDescription` も併記する
（現状のデプロイメントターゲットは iOS 17 なので不要）。

### 2. Xcode プロジェクトへの組み込み

このパッケージはローカル Swift Package として組み込む想定。

1. Xcode でアプリプロジェクトを開き、このリポジトリのルート（`Package.swift` がある階層）を
   プロジェクトナビゲータにドラッグする。
2. アプリターゲットの *General → Frameworks, Libraries, and Embedded Content* に
   `CatCore` と `CatPlatform` の両方を追加する。
3. 組み立ては次のようになる。

```swift
import CatCore
import CatPlatform

let source = EventKitCalendarSource()
await source.requestAccess()          // 初回のみ。権限ダイアログを出す

let layer = CalendarLayer(
    source: source,
    geocoder: AppleGeocodingService(),
    repository: Repository(store: try ApplicationSupportFileStore()),
    calendar: Calendar.current        // Calendar の注入はここ1か所だけ
)

let result = try await layer.refreshOnLaunch(now: Date())
```

`refreshOnLaunch` はアプリ起動時に1回呼べばよい。バックグラウンド実行は不要
（完了判定が「開始時刻を過ぎたか」だけなので、起動時に全件評価すれば足りる）。

### 3. Mac 上で最初に確認すべきこと

CatPlatform は Linux 上で一度もコンパイルされていない。Mac に持っていったら、まず
`swift build` が通ることを確認してほしい（詳細は次節）。

---

## 実装できなかった項目・仕様が曖昧で判断に迷った箇所

仕様書側の修正が要りそうなものには **[要検討]** を付けた。

### A. 実装できなかった／検証できなかったもの

1. **CatPlatform は一度もコンパイルされていない。**
   この環境は Linux で Xcode が無いため、`EventKitCalendarSource` /
   `AppleGeocodingService` / `ApplicationSupportFileStore` は
   `#if canImport(EventKit)` の中に書かれたまま、構文チェックすら通っていない。
   ロジックは CatCore 側に寄せてあるので詰め替えだけのはずだが、**Mac 上で最初に
   ビルドを通す作業が必要**。特に不安なのは次の2点。
   - `EKEvent.occurrenceDate` を非オプショナルの `Date` として受けている
     （`let occurrenceDate: Date = event.occurrenceDate`）。SDK 側が `Date!` でも
     この書き方なら通るはずだが、実際に確認していない。
   - `MKError.Code` の `.loadingThrottled` / `.serverFailure` の綴り。
2. **CatPlatform のテストが無い。** Linux では実行できないため。Mac 側で
   `EKEvent → CalendarEvent` の変換（特に `structuredLocation` の有無での分岐）と、
   `AppleGeocodingService` のエラー分類にはテストを足したほうがいい。
3. **後続フェーズのもの**（移動時間、天気、通知、UI、週次サマリー）は仕様どおり未実装。

### B. 仕様の矛盾に見えた箇所と、その解決

#### B-1. [要検討] `EventKey` に開始時刻が入っているのに「開始時刻の変更＝編集1回」

仕様 4-1 は `EventKey = eventIdentifier + startDate`、仕様 6 のテスト要件は
「開始時刻を変更 → editCount が 1」。この2つは素直に読むと両立しない。開始時刻がキーの一部なら、
時刻を動かした瞬間にキーが変わり、**編集ではなく「削除＋新規」**として見えてしまう。

`EventSnapshot` が `key` とは別に `startDate` を可変フィールドとして持っていることから、
**`EventKey.startDate` は「識別のための時刻」で、動かしてはいけない値**だと解釈した。
そのうえで `EventKitCalendarSource` では `EKEvent.startDate` ではなく
**`EKEvent.occurrenceDate`（その回の元の開始時刻）** をキーに使っている。単一の回の時刻を
ユーザーが動かしても `occurrenceDate` は変わらないので、繰り返し予定については意図どおり動く。

**残る問題**: 繰り返しでない予定は `occurrenceDate == startDate` なので、時刻を動かすと
やはりキーが変わる。つまり「単発の予定の時刻変更」は今も削除＋新規として扱われ、編集回数が
リセットされる。編集回数の上限が「予定を動かしすぎたら諦める」ためのものだとすると、これは
抜け穴になっている。仕様書側で、キーに使う時刻を `occurrenceDate` と明示するか、
`CalendarEvent` に識別用の不変フィールドを1つ足すかを決めてほしい。

#### B-2. [要検討] 第2段階の「空き枠があれば追加」と「解放された枠に繰り上がらない」

仕様 5-4 の第2段階は「空き枠がある場合のみ registrationOrdered の順で追加」と書いてあり、
枠の解放は「解放された枠に、既存の枠外予定が自動的に繰り上がることはありません」と書いてある。
テスト要件にも「枠内の予定を1件削除 → 枠が1つ空く」と「枠が空いた後、既存の枠外予定は
繰り上がらない」の両方がある。`confirmedKeys.count < slotLimit` を素直に「空き枠」と読むと、
削除で空いた枠に枠外予定が入ってしまい後者に反する。

**「空き枠 ＝ 一度も埋まらなかった枠」であり、一度埋まってから解放された枠は再利用しない**、と
解釈した。この読みなら要件が全部整合する。

- 第1段階で2件しか確定しなかった → 3枠目は一度も埋まっていない → 追加できる
- 第1段階で3件確定 → 空き枠なし → 追加できない
- 1件削除で `confirmedKeys` は2件になるが、その枠は消費済み → 追加できない

**ただし、これを起動をまたいで保つには状態が足りない。** `confirmedKeys` だけを見ると、
次回起動時には「2件しか埋まっていない＝1枠空いている」と誤認して枠外予定が繰り上がってしまう。
そこで **`DailySlots` に `releasedSlotCount: Int` を1つ足した**（仕様書に無いフィールド）。
追加可能な枠数は `slotLimit - confirmedKeys.count - releasedSlotCount` で計算している。
既存データとの互換のため、デコード時に無ければ 0 として扱う。

このフィールドが不要（＝解放された枠は再利用してよい）なら、仕様書の
「繰り上がることはありません」を消してほしい。逆に、この不変条件が本当に重要なら、
仕様書側にもフィールドを明記したほうがいい。

#### B-3. [要検討] 「登録順」をどこから取るのか

第2段階は `registrationOrdered`（登録順）で追加すると書かれているが、`CalendarEvent` に
作成日時のフィールドが無く、EventKit の predicate も登録順では返さない。

現状は **`CalendarSource.fetchEvents` が返した順序をそのまま登録順として扱っている**。
`EventKitCalendarSource` は仕様 7 の指示どおり「開始時刻昇順、同一なら eventIdentifier 昇順」で
ソートして返すので、**実際には登録順ではなく開始時刻順になっている**。

真の登録順が要るなら `CalendarEvent` に `creationDate`（`EKEvent.creationDate`）を足して、
`CalendarLayer` 側でそれを使ってソートする必要がある。

#### B-4. [要検討] 第2段階の登録順と、ジオコーディング3回の上限が衝突する

`LocationResolver` は開始時刻順に処理して枠が埋まった時点で打ち切る。そのため第2段階で
空き枠が1つのとき、**枠の候補になれるのは「開始時刻がいちばん早い未確定の予定」1件だけ**で、
`registrationOrdered` が何を先頭に置いていても結果は変わらない。つまり第2段階の追加は
事実上「開始時刻順」になる。

登録順を本当に効かせるには、空き枠数より多くの予定をジオコーディングする（＝呼び出し回数が
増える）しかない。「通常ちょうど3回」の要件と両立しないので、現状は3回優先にしてある。

#### B-5. 逐次解決と「既に枠を持っている予定」の順序（実装で補った）

仕様 5-8 の手順どおり「対象日の候補を開始時刻順に並べて先頭から解決」すると、次の壊れ方をする。

> 枠が `[10:00, 11:00, 12:00]` で確定済みのところに、あとから 9:00 の予定が登録される。
> 解決は 9:00 → 10:00 → 11:00 で打ち切られ、**12:00 の予定の座標が取れない**。
> しかも 12:00 は「slotEligible に居ない」ので枠から外れてしまう。

`CalendarLayer` では第2段階のとき **解決を2回に分けている**。

1. 既に枠を持っている予定だけを解決する（枠数ぶん）
2. 空き枠が残っていれば、その数だけ残りの予定を解決する

合計の呼び出し回数は枠数を超えない。あわせて、「解決まで到達しなかったがカレンダーには
残っている予定」は枠から外さないようにしてある（解決の打ち切りと外部削除を区別する）。

#### B-6. 「前日未起動」の除外を、ジオコーディングの前にも適用した

「開始時刻が now より前の予定は対象から除外」は仕様 5-4（枠の確定）にしか書かれていないが、
座標解決の前に適用しないと意味がない。14:00 に起動したとき 9:00 / 11:00 / 13:00 の解決で
3回を使い切り、枠に入るはずの 15:00 / 18:00 が未解決のまま候補から漏れてしまう。
`CalendarLayer` では `SlotConfirmer` と同じ条件（対象日が今日、かつ第1段階、かつ非 Premium）で
解決前にも除外している。

#### B-7. [要検討] 第2段階には「開始済みの予定を除外する」ルールが無い

B-6 の除外は第1段階だけの規定なので、仕様どおりだと**第2段階では既に始まってしまった予定でも
枠に入れる**ことになる。意図的なのか書き漏れなのか判断が付かなかったので、仕様のまま
（除外しない）にしてある。

### C. 仕様に書かれていなくて自分で決めたこと

1. **`LaunchResult` のキー配列の対象範囲。**
   `todayEvents` と `conflicts` が今日のものなので、`editLimitExceededKeys` /
   `outOfSlotKeys` / `noLocationKeys` / `allDayKeys` / `carriedOverKeys` も
   **すべて今日ぶんだけ**にした。翌日は `tomorrowSlots` から後続フェーズで導出する想定。
   （`carriedOverKeys` は「対象日ごとに変わる」値なので、今日と翌日を混ぜると
   「9/1 では含まれない／9/2 では含まれる」が表現できなくなる。）
2. **`noLocationKeys` の定義。** 「実際にジオコーディングまで到達したのに座標が無いもの」。
   `.temporaryFailure` の予定は枠を持ったまま座標が無いので、ここに含まれる。
   枠が埋まって解決を試みなかった予定は含めない（試していないので「解決できなかった」とは
   言えないため）。
3. **`editLimitExceededKeys` は `editCount >= 3`。** Premium では常に空。
4. **ジオコーディングのキャッシュキー。** `locationText` の前後の空白を除いた文字列。
   大文字小文字や全角半角の正規化はしていない。
5. **`ChangeDetector` の完了判定の順序。** 「変更を比較 → その後で完了フラグを立てる」。
   凍結の判定には**保存済みのフラグ**を使うので、「開始時刻を過ぎた予定が同じ起動で
   編集されていた」場合は編集1回として数え、そのうえで完了にする。凍結が効くのは次回起動から。
6. **取得範囲の外にあるスナップショットは削除判定から外す。** 取得は3日前からなのに完了済み
   スナップショットは14日残るので、そのまま渡すと「取得結果に無い＝削除された」と誤判定する。
   完了済みは保持されるルールのおかげで実害は出にくいが、明示的に範囲外を除外してある。
7. **Premium の `confirmedAt`。** 段階分けを適用しないので、既存値があればそれを維持し、
   無ければ `now` を入れる。
8. **`RetentionPolicy` の境界。** スナップショットは完了から14日 **以上**で削除（13日は残る）。
   枠は「3日前の0時より前」を削除（3日前ちょうどは残る）。失敗キャッシュは24時間以上で削除。
9. **`EventConflict` に `Codable` を足した。** 仕様 4 の「すべて Codable と Equatable に
   準拠させる」に合わせた。4-6 のシグネチャは `Equatable` だけだったので、追加分。
10. **`AppleGeocodingService` のエラー分類。** 仕様は `CLError.network` だけを一時失敗と
    しているが、`MKLocalSearch` 側にも一時的な失敗（`.loadingThrottled` / `.serverFailure`）が
    あるので同じ扱いにした。`CLGeocoder` が種類の判別できないエラーを返した場合は、
    そこで打ち切らず `MKLocalSearch` にフォールバックする。
11. **`ApplicationSupportFileStore.read` はファイルが無ければ `nil`**（例外にしない）。
    `Repository` 側はどちらでも空データとして扱うが、「無い」と「壊れている」を
    呼び出し側で区別できるようにしてある。
