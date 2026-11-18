# Verification and remaining release work

Verified using Flutter 3.50.0 stable / Dart 3.14.0 on Linux, 17 November 2026.

- `flutter analyze`: no issues, with Flutter recommended lints enabled.
- `flutter test --reporter expanded`: all 14 tests passed.
- `flutter build web --release`: successful JavaScript release compilation; Flutter's Wasm compilation dry run also passed. The Wasm runtime itself was not tested.
- Chromium smoke check: game rendered, Space launched an arrow, P paused/resumed, store opened, and no uncaught JavaScript page errors were recorded. A headless software-rendering browser was used. The test browser ignored this environment's HTTPS certificate interception for Google font downloads; that browser setting is not shipped in the application.
- Captures of the actual Web release were inspected for playfield/HUD and store layout.

Tests cover all 250 stage blueprints and final-boss hazards; 30/60/120 Hz simulation consistency; segment and wrapped-arc geometry; successful embeds, stars and stage unlocks; working laser collisions; solid 12%-opacity phantom pins; nonstop endless waves; three-heart deaths and one continue; fever activation and doubled rewards; pause/suspension; progression and boss-skin gates; unavailable billing/ad defaults; serialized save roundtrips, corrupt-save recovery and value sanitization; startup when the next stage is in an unowned pack; and small-screen/wide-screen UI, keyboard input, armory, store and stage selector.

## Release gates that have not been completed

1. Native Android/iOS/Windows builds and real-device QA. This host has no Android SDK, Xcode or Windows build tools. Platform shells are included for convenience and remain release configuration templates.
2. Configure final bundle/application IDs, app icons, signing and store listings. The Android template does not substitute debug signing for a release keystore.
3. Wire real purchases and rewarded ads through `CommerceHooks`. Verify purchases/restore, receipts, cancellations, disconnects, ad reward timing, consent/privacy requirements and product pricing against the provider's sandbox. Reconcile cached entitlements with trusted store/backend data.
4. Profile frame times, battery, thermal behavior and memory on representative native devices. The code targets smooth frame pacing; a universal 60 FPS result is not certified by these tests.
5. Playtest all stage layouts and difficulty curves, including stage 250. Automated blueprint checks are not a proof of every-stage solvability or fun/balance.
6. If offline Web operation is required, bundle fallback fonts. CanvasKit is served locally by the supplied Web bootstrap, but Flutter's automatic text/emoji fallback can fetch Google fonts.

No signed binaries, live transactions, real ad impressions or external publishing were performed. SharedPreferences saves are local and can be edited/cleared by the device owner; they are not a secure entitlement authority.

Android 1.1.0 update: Flutter analysis reported no issues, and all 16 tests passed. Both ARM release APKs built successfully and passed signature verification. Physical-device testing of ad display remains open. The APKs use AdMob sample IDs and a test signing key.

Android 1.1.1 update: analysis passed and all 17 Flutter tests passed, including independent sound and vibration preference persistence. Both Android APKs built and their signatures, VIBRATE permission, and all four audio files were verified. Device audio and vibration strength were not exercised.

Android 1.1.2 update: manifest and launch resources link successfully. Both ARM APK signatures and packaged launch resources were checked. Analysis and all 18 Flutter tests passed, including the splash-to-saved-stage transition. Native cold launch was not tested on a phone.

Android 1.1.3 recovery: restored the Android manifest-compatible launch themes and drawables from 1.1.1. Both ARM APKs build, verify, and match the previous release's signing certificate. Flutter analysis and all 18 tests passed. The reported device crash could not be reproduced or verified without a device log.

Android 1.1.4: Flutter analysis and all 18 tests passed. Both release APKs built, verified, and retained the prior signing certificate. Android manifest includes the compatibility renderer setting, and optional game feedback and ads are initialized on demand. A device cold-start check and the reported crash trace remain unavailable.

Android 1.1.5 recovery: all Dart application files and Android app source files match the pre-splash 1.1.1 source byte for byte. Flutter analysis passed. Both release APKs built and use the same signing certificate as 1.1.4. A device cold-start check and the reported crash trace remain unavailable.

Android 1.2.0: analysis and all 16 tests passed, including in-flight arrow counting and splash-to-saved-stage behavior. Both signed APKs verify and contain the four sound resources. The 64-bit build retains the pre-splash Android launch configuration and excludes the Mobile Ads SDK. Physical Android startup and audio playback remain unverified. Recovery APK content matches the user-tested original except for its manifest update code and renewed signing block.

Web 1.2.0: production compilation succeeded. The deployed bundle includes the splash, in-orbit counter, local CanvasKit and versioned startup scripts. The managed live preview relay timed out, so visual browser QA was unavailable.

Version 1.3.0: Flutter analysis and all 17 tests passed, including a wheel purchase through the small-screen Armory, profile reload, and re-equipping without charging. Production web compilation succeeded and the 64-bit APK passed signature and alignment verification. Android device playback and live rewarded ads were not tested.

Version 1.4.0: analysis and 20 Flutter tests passed. Tests cover charging once, saved entry rights, the post-two-clear promotion, and full access in VIP and Test. Both Android APKs passed signature and alignment checks and had distinct launcher labels and package IDs. The signed builds were not launched on a physical phone. Network ads and paid checkout are not connected.

Version 1.4.1: analysis and all 21 tests passed, including the fourth-retry placement and VIP bypass. Web release compilation succeeded. The 64-bit APK retained the previous signing certificate and passed APK alignment verification. The Test APK remains unrestricted.
