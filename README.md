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
Executed 99 tests, with 0 failures
```

`CatPlatform` は Linux 上では `#if canImport(EventKit)` が偽になるため中身が空になる。
ビルドは通るが、**Linux 上では CatPlatform のコードは一行もコンパイルされない**
（後述の「実装できなかった項目」を参照）。

テストの対象内訳:

| ファイル | 件数 | 内容 |
| --- | --- | --- |
| `CompletionEvaluatorTests` | 5 | 開始時刻の境界、終日予定 |
| `ChangeDetectorTests` | 14 | 編集回数、完了後の凍結、削除、繰り返し予定 |
| `LocationResolverTests` | 12 | キャッシュ規則、逐次実行、処理順、枠の打ち切り |
| `MockGeocodingServiceTests` | 1 | 「並行実行を検出できる」ことの確認 |
| `SlotConfirmerTests` | 22 | 第1/第2段階、枠の解放、日跨ぎ、繰り返し、Premium |
| `ConflictDetectorTests` | 8 | 同時刻/部分重複/境界接触/終日 |
| `RepositoryTests` | 11 | 往復、壊れた JSON、書き込み失敗 |
| `RetentionPolicyTests` | 6 | 14日 / 3日 / 24時間 |
| `CalendarLayerTests` | 20 | 統合（権限・枠・登録順・日跨ぎ・再起動・期限切れ削除） |

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

## 仕様の決定内容

実装中に上がった仕様の矛盾は3点とも決着済み。決定内容と理由は
[docs/spec-decisions.md](docs/spec-decisions.md) に記録している。

1. **`EventKey` から開始時刻を外した。** 単発予定は `eventIdentifier` のみ、
   繰り返し予定は `eventIdentifier` + `occurrenceDate`。開始時刻を動かしても
   同一の予定として認識され、「開始時刻の変更 = editCount 1」が正しく機能する。
2. **`CalendarEvent` に `creationDate` を追加した。** 第2段階の追加順が実際に
   登録順で決まるようになった。あわせて `LocationResolver` に処理順の指定を足している
   （解決の順序がそのまま枠の候補を決めてしまうため）。
3. **枠の解放は「支援を送信したか」で決める。** 送信前に消えた予定の枠は返し、
   送信後に消えた予定の枠は返さない。`EventSnapshot.supportSentAt` と
   `DailySlots.supportSentSlotCount` がこの判定を持つ。

なお、**この変更以前に保存されたデータとは互換性が無い**（`EventKey` の形が変わったため）。
未リリースなので移行処理は入れていない。

## 実装できなかった項目

1. **CatPlatform は一度もコンパイルされていない。**
   この環境は Linux で Xcode が無いため、`EventKitCalendarSource` /
   `AppleGeocodingService` / `ApplicationSupportFileStore` は
   `#if canImport(EventKit)` の中に書かれたまま、構文チェックすら通っていない。
   ロジックは CatCore 側に寄せてあるので詰め替えだけのはずだが、**Mac 上で最初に
   ビルドを通す作業が必要**。特に不安なのは次の3点。
   - `EKEvent.occurrenceDate` を非オプショナルの `Date` として受けている。
   - `EKCalendarItem.hasRecurrenceRules` / `EKEvent.isDetached` の綴りと意味。
   - `MKError.Code` の `.loadingThrottled` / `.serverFailure` の綴り。
2. **CatPlatform のテストが無い。** Linux では実行できないため。Mac 側で
   `EKEvent → CalendarEvent` の変換（特に繰り返し判定と `structuredLocation` の
   有無での分岐）と、`AppleGeocodingService` のエラー分類にはテストを足したほうがいい。
3. **後続フェーズのもの**（移動時間、天気、通知、UI、週次サマリー）は未実装。
   `EventSnapshot.supportSentAt` に値を入れるのも通知フェーズの仕事で、
   `Repository.markSupportSent(for:at:)` を呼び口として用意してある。
