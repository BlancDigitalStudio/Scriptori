# Scriptori — Architecture & Implementation Plan

Scriptori turns doomscrolling into **bloomscrolling**: a full-screen vertical feed that walks the
reader through one Bible chapter per day, ending with a short guided reflection that completes the
day and grows a streak.

## 1. Repository layout

```
Scriptori.xcodeproj          iOS app project (Swift 6, iOS 17+, iPhone)
Scriptori/                   App target (folder-synchronized: new files are picked up automatically)
  App/                       ScriptoriApp entry, AppModel (routing + orchestration), RootView
  DesignSystem/              Palettes, typography, shared components (Chip, FlowLayout, StreakBadge)
  Features/
    Feed/                    ScriptoriFeedView, VerseCardView, intro/themes/checkpoint/reflection cards, 1–3 picker
    Reflection/              ReflectionView (mood → takeaways → questions; new or edit), CompletionCelebrationView
    Library/                 BookCard, BookLibraryView, BookPreviewView, book-choice screens
    Onboarding/              Intent quiz → recommended books + library → plan → reading cue → pace
    Paywall/                 PaywallView (trial, Monthly/Annual toggle, Save 20% badge)
    Auth/                    SignInView (Apple, Google, email)
    Journal/ Profile/ Share/
  Services/                  Platform services: StoreKit 2, Auth, Firestore sync, notifications,
                             ambient audio, haptics
ScriptoriKit/                Swift package with all platform-independent logic + unit tests
  Sources/ScriptoriKit/
    Models/                  BibleBook, BibleChapter, ChapterTheme, ReflectionEntry, UserProfile, OnboardingAnswers…
    Services/                StreakEngine, VersePaginator, ChapterSession, ChapterCompletionService
    Persistence/             LocalStore (offline-first JSON store)
    Content/                 BundledContentLibrary (per-book loading, guide or fallback reflection)
    Resources/               Books.json (catalog), Bible/KJV/<BOOK>.json (text), Guides/<BOOK>.json (authored guides)
scripts/build_bible.py       Regenerates Bible/KJV and Books.json from the public-domain KJV
Config/                      Info.plist additions, entitlements, Scriptori.storekit (local IAP testing)
```

Why a package? Streaks, pagination and completion rules are the heart of the product and must be
correct across time zones, month boundaries and edge cases. Keeping them in a UI-free package makes
them testable in milliseconds (`swift test`) and portable to a server or a Kotlin port.

## 2. Architecture

MVVM with the Observation framework (`@Observable`, `@MainActor`):

| Layer | Types | Responsibility |
| --- | --- | --- |
| Views | `ScriptoriFeedView`, `ReflectionView`, `PaywallView`… | Render state, forward intents |
| App model | `AppModel` | Routing (`launching → onboarding → signIn → paywall → main`), wiring services, completion transaction |
| Feature model | `ChapterSession` | Feed items, 1–3 regrouping, focus/anchor, marked verses and checkpoint notes, progress persistence |
| Domain services (pure) | `StreakEngine`, `VersePaginator`, `ChapterCompletionService`, `DailyReadingResolver`, `BookRecommender` | Business rules; no side effects |
| Platform services | `SubscriptionService`, `AuthService`, `ProfileSyncing`, `NotificationScheduler`, `AmbientAudioService`, `Haptics` | Talk to Apple frameworks / backend |
| Persistence | `LocalStore` actor | Offline-first JSON files per user (file protection: complete) |

Data flow for completing a day:

1. The feed's last card shows a one-tap mood check-in, which opens `ReflectionView`.
2. On submit, `AppModel.submitReflection` calls `ChapterCompletionService.complete(...)`. It checks that
   every verse card was seen and the reflection passes (mood selected and at least one question
   answered), then returns an updated `UserProfile` with the new streak, totals and plan position.
3. `AppModel` saves the result locally, re-plans reminders, plays haptics, shows the celebration, and
   pushes to Firestore in the background. If the push fails, the entry stays `pending` and is retried on
   the next sign-in.

## 3. Core rules

**Onboarding.** Two intent questions (why you're here, how familiar you are with the Bible) feed
`BookRecommender`, which ranks books from `Books.json` by matching `intents` and comfort `level`.
The reader picks a recommended book or browses all 66, sees a "Your plan" summary, ties reading to an
everyday cue (which the daily reminder quotes), and chooses verses per card. Answers are stored on
the profile as `onboarding`.

**Daily chapter.** The reader reads one book, one chapter a day, in order. `DailyReadingResolver`
serves chapter `position + 1` of `plan.bookID`. After completion, the same chapter stays on screen
(as "completed") until the next local day, then the next chapter is served. When the book is finished
the Today tab offers the next book. Readers switch books by tapping the chapter title on the Today tab
or from Profile → Your book; the chosen book opens on the Today tab ready to read right away, resuming
where they left off if they'd started it before (`plan.savedPositions`). Finishing a chapter of the
new book on a day that's already complete counts toward chapters read but doesn't grow the streak
twice. Profiles without a `bookID` (including ones from the old fixed plan) are sent to the book picker.

**Themes and guides.** Chapters with an authored guide show a themes card (at most 3 themes, each with
an icon, a one-line summary and a key verse) after the intro, and the reflection's takeaway chips list
those themes first. Chapters without a guide get a general fallback reflection.

**Long chapters.** Readers can mark verses (bookmark button or double-tap). Chapters over 40 verses get
a checkpoint card roughly every 30 verses with a recap of marked verses and an optional note. While
reflecting, marked verses and notes are shown as tappable quotes, a Re-read sheet shows the whole
chapter, and verses cited by a question ("Verse 8…") appear inline.

**Editing reflections.** Entries can be edited from the Journal, or from the Today tab while it's still
the same day. Edits set `updatedAt` and re-sync; they never change the streak or plan. When local and
remote copies differ, the most recently modified one wins.

**Verse grouping (1–3).** `VersePaginator` splits a chapter into cards whose id is their first verse.
`ChapterSession` stores the reader's *anchor verse* (the first verse of the card they last swiped to).
Regrouping re-paginates around that anchor, so going 1 → 3 → 1 lands back on the exact verse. The
choice is saved as the user's default; values saved under the old 1–5 range are clamped to 3.

**Streaks + Streak Repair.** `StreakEngine` is keyed on local `DayKey`s:
- Completing on consecutive days extends the streak; completing twice in a day is a no-op.
- If exactly one day was missed, the streak is *repairable* until `graceHours` (default 24) after the
  missed day ended, i.e. through the end of the following day. Repairs are limited to one per
  `repairCooldownDays` (default 7) so the buffer remains a safety net.
- Milestones at 3, 7, 14, 30, 50, 100, 200, 365 days trigger confetti and a triple haptic.

**Subscriptions.** StoreKit 2: one group, `com.scriptori.premium.monthly` and
`com.scriptori.premium.annual`, each with a 3-day free introductory offer. The annual price is set at
~20% below 12 × monthly (sample: $4.99/mo and $47.99/yr). The "Save N%" badge is computed from live
prices. Access is decided from `Transaction.currentEntitlements`. A hard paywall appears after
onboarding and sign-in, and again whenever entitlement lapses (for example, when a trial expires
without converting). A local notification goes out 24 hours before a trial ends.

## 3a. Backend & billing decisions

- **Backend: Firebase** (Auth, Firestore, Cloud Functions; later Cloud Messaging, Crashlytics,
  Analytics, Remote Config). Chosen over Supabase for built-in offline sync in the native SDKs and
  the all-in-one mobile tooling.
- **No RevenueCat.** Users are expected to stay on one platform, so a shared cross-store entitlement
  isn't needed.
- **iOS billing:**
  - *At launch:* StoreKit 2 with on-device verification only, as built. No server is required to
    unlock the app.
  - *With the Android work:* add a Cloud Function that receives **App Store Server Notifications v2**.
    It verifies Apple's signed payload with `@apple/app-store-server-library`, maps the purchase to
    the user via `appAccountToken`, and writes `users/{uid}.subscription`. This gives records and
    analytics only. The app keeps deciding access from StoreKit on the device, so a backend outage
    never locks out paying users.
  - Once the function owns `subscription`, stop the app from writing that field and deny client
    writes to it in Firestore security rules.
- **Android billing:** native Google Play Billing Library plus a Cloud Function. The function
  verifies purchases with the Play Developer API, acknowledges them within 3 days, consumes Real-time
  Developer Notifications (via Pub/Sub), and writes the same `users/{uid}.subscription` shape.

## 4. Data schema (Firestore)

```
users/{uid}                         UserProfile
  streak { current, longest, lastCompletedDay "YYYY-MM-DD", lastRepairDay, recentDays[] }
  totalChaptersRead, reflectionCount
  subscription { tier, isInTrial, expiresAt, willAutoRenew }   // mirrored; the store is source of truth, written by Cloud Functions once added (see 3a)
  preferences { versesPerCard, typeface, ambientSound, remindersEnabled, reminderHour, reminderMinute }
  plan { planID, bookID, position, lastCompletedDay, lastCompletedChapterID, savedPositions{bookID: position} }
  onboarding { intent, familiarity, bookID, cue }
users/{uid}/reflections/{uuid}      ReflectionEntry
  chapterID, chapterReference, day, createdAt, updatedAt, mood, takeaways[], highlights[],
  answers[{questionID, prompt, choice, text}]
```

Suggested security rules: `allow read, write: if request.auth.uid == uid;` on both paths. Once
Cloud Functions write `subscription`, add a rule that rejects client writes touching that field.
Completion validation can move to a Cloud Function later if streak tampering becomes a concern.

## 5. Setup

1. Open `Scriptori.xcodeproj` and set your Team and bundle id (default `com.scriptori.app`).
2. Run the **Scriptori** scheme. It is preconfigured with `Config/Scriptori.storekit`, so purchases
   and the 3-day trial work in the simulator without App Store Connect. (If Xcode doesn't pick up the
   file, choose it under *Edit Scheme → Run → Options → StoreKit Configuration*.)
3. Debug shortcuts: launch arguments `-demo` (go straight to the feed as a guest) and `-demo-paywall`.
   The paywall and sign-in screens also show debug-only skip/guest buttons.
4. Run logic tests with `cd ScriptoriKit && swift test`, or the ScriptoriKit scheme in Xcode.

### Enabling Firebase (Google + email sign-in, cloud sync)

The Firebase integration is compiled only when the SDKs are linked (`#if canImport(...)`). Without
it, the app runs fully local: Sign in with Apple works natively, and email/guest sign-in work in
Debug.

1. File → Add Package Dependencies: `https://github.com/firebase/firebase-ios-sdk` (add
   `FirebaseAuth`, `FirebaseFirestore`) and `https://github.com/google/GoogleSignIn-iOS` (`GoogleSignIn`).
2. Add `GoogleService-Info.plist` to `Scriptori/` (it's git-ignored).
3. Add the `REVERSED_CLIENT_ID` URL scheme for Google Sign-In.
4. Enable Apple, Google and Email/Password providers in the Firebase console.

### App Store Connect

Create the subscription group and both products with the same ids, attach a 3-day free-trial
introductory offer to each, enable Sign in with Apple, and replace the Terms/Privacy URLs in
`PaywallView`.

### Optional assets and IDs

- No audio assets are needed: the soft rain, waves and wind ambient modes are generated
  procedurally, and a verse card's Listen button reads it aloud with `AVSpeechSynthesizer`
  (tap again to stop).
- Set `facebookAppID` in `ShareCardSheet` to enable direct "Share to Instagram Stories". The system
  share sheet works without it.

## 6. Content

The full public-domain KJV (66 books, 1,189 chapters, about 4 MB) is bundled as one JSON file per book
in `Resources/Bible/KJV/`, generated by `scripts/build_bible.py`. `Books.json` holds the catalog
(category, blurb, themes, onboarding intents, reading level, minutes per day).

Authored chapter guides live in `Resources/Guides/<BOOK>.json`, keyed by chapter id. Each has an
optional `title` and `palette`, up to 3 `themes` (`title`, `summary`, SF Symbol `symbol`, `keyVerse`),
`takeaways`, and 2–3 `questions`. Guides currently exist for Psalms 1, 23, 46 and 121, and all of
Philippians. Every other chapter uses the general fallback reflection (no themes card) until a guide
is written; prioritize guides for the books onboarding recommends most. To scale:
- Replace `BundledContentLibrary` with a remote `BibleContentProviding` (for example, API.Bible for
  licensed translations such as NIV/ESV, or bundle the public-domain WEB/KJV in full).
- Author reflections in a CMS (or Firestore `chapters/{id}`) so they can be updated without a release.
- Please proofread the bundled verses against your chosen source edition before shipping.

## 7. Android (planned)

Mirror the same architecture in Kotlin + Jetpack Compose: `VerticalPager` for the feed, a Kotlin port
of `ScriptoriKit` (the rules are deliberately pure and small), Firebase Auth/Firestore with the same
schema, native Google Play Billing with a verification Cloud Function (see 3a), WorkManager plus
notifications for reminders, and `VibrationEffect` for haptics. Keeping the Firestore schema and
product ids identical means a user who switches platforms keeps their streak and reflections; they
would need to subscribe again in the new store.

## 8. Roadmap

1. **MVP (this codebase):** feed, regrouping, reflections, streaks + repair, StoreKit 2 paywall,
   Apple sign-in, reminders, ambient mode, share cards, journal.
2. **Firebase on:** add the SDKs and config, enable Google and email sign-in, turn on cloud sync, and
   add analytics (paywall views, trial starts, D1/D7 retention).
3. **Android + billing backend:** the Kotlin app with Play Billing; Cloud Functions for Play
   verification/RTDN and App Store Server Notifications v2; make `subscription` server-owned.
4. **Growth:** home-screen and lock-screen widgets (today's verse plus streak), Live Activity for
   Streak Repair, referral share links on Scriptori Cards, multiple reading plans, paywall A/B
   tests via Firebase Remote Config.
