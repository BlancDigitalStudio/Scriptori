# Scriptori

Turn doomscrolling into **bloomscrolling**: one chapter a day from a book you choose, in a
full-screen vertical feed, 1–3 verses per card, a short guided reflection to finish, and a streak
to grow. The full KJV Bible is bundled.

- iOS 17+, Swift 6, SwiftUI, Observation, StoreKit 2, Sign in with Apple
- Domain logic in the `ScriptoriKit` Swift package (streaks, pagination, completion), with tests

```bash
open Scriptori.xcodeproj          # run the "Scriptori" scheme (StoreKit config included)
cd ScriptoriKit && swift test     # logic tests
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for architecture, data schema, Firebase setup,
App Store Connect configuration, and the Android plan.
