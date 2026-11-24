# Orbit Arrow: Overdrive

All application logic is in `lib/main.dart`. The provided attachment was treated as reference code, not as instructions. No original HTML/JavaScript source was supplied, so this implements the requested mechanics and completes the Dart draft rather than claiming pixel-identical HTML parity.

## Run

The ZIP includes Android, iOS, Windows and Web project shells; unzip it and run `flutter pub get`. These shells were generated with Flutter 3.50.0. Signing, app icons and provider configuration still need your release setup.

For just the single-file application, use recent stable Flutter (Dart >=3.8) and create shells yourself:

```sh
flutter create --platforms=android,ios,windows,web orbit_arrow_overdrive
cd orbit_arrow_overdrive
# Replace lib/main.dart with the delivered file.
flutter pub add shared_preferences
flutter run -d chrome
```

Alternatively copy the supplied `pubspec.yaml` and `test/game_test.dart` as well. Delete Flutter's generated `test/widget_test.dart`, which targets its counter example.

```sh
flutter analyze
flutter test
flutter build web --release
flutter build appbundle --release    # Android SDK + signing required
flutter build ios --release         # macOS + Xcode + signing required
flutter build windows --release     # Windows + Visual Studio toolchain required
```

The game code requires no custom assets, fonts, network requests, or platform-specific imports. Flutter Web may fetch fallback fonts from Google; an offline deployment must bundle appropriate fonts. The supplied project scaffold serves CanvasKit locally via web/flutter_bootstrap.js, avoiding an engine CDN dependency. Android/iOS/Windows/Web are supported by Flutter and shared_preferences. Native builds must be verified on their corresponding build hosts. The app letterboxes its 420 × 760 arena on any orientation/window size; simulation and input use this same coordinate system.

## Controls and mechanics

Tap/click the playfield or press Space to launch. P/Escape pauses. Buttons never launch arrows. Window focus loss pauses the game and requires explicit resume. Only one arrow can fly at once; rapid *accepted* shots build fever. Holding a key does not autofire.

The wheel supports constant, pulse, full reverse every 2.5 simulation seconds, and staccato movement. Hazards use the same geometry for collision and rendering. Arrows keep their launch x while the core drifts. Phantom pins remain solid at 12% opacity. Shields collide with the arrow shaft; floating gems can be collected once per wave. Close calls give electric sparks and score. Fever lasts 3.2 real play seconds, slows simulation to 48%, and doubles collected gems and stage rewards.

Stages 1–50: Neon Orbit. 51–100: Twin Vortex. 101–150: Phantom Pulse. 151–200: Gravity Drift. 201–250: Omega Overdrive. Every fifth stage is a boss; stage 250 combines all hazards with three laser shields. Modes and stage layouts are deterministic. Speed and hazards increase with progression. Star ratings are based on completion time: three stars within 2.4 seconds per required arrow, two within four seconds, otherwise one. Stars can only improve on replay.

Endless is free, has three hearts and automatic wave transitions. On a nonfatal collision, the failed arrow is refunded and the struck pin removed. Best wave means the highest wave reached; score means the best score recorded in a run/stage. Endless speed and arena density are bounded so difficulty doesn't become numerically unstable. A run allows one earned-ad continue, restoring three hearts. Restart resets the run.

Seven armory skins have distinct shapes. Cyber Dart is free; Midas, Crimson and Emerald cost gems. Stage 5 unlocks Sawblade Trophy; stage 10 unlocks Chrono Void; stage 250 or VIP unlocks Omega Sovereign. Locked trophy skins cannot be bought for zero gems.

## Persistence

A versioned JSON snapshot in SharedPreferences saves progression, best stars, gems, owned/equipped skins, best score/wave, haptics and cached entitlements. Writes are serialized and happen at gameplay events, not every frame. Corrupt saves recover to defaults with a visible message. Active arrows and partially completed runs are not restored. Browser private mode/storage eviction and uninstalling the app may remove saves. SharedPreferences is a local casual-game save, not a tamper-resistant financial entitlement database or cloud backup.

## Live billing and rewarded ads

The requested prices are represented as product hooks:

| Product ID | Intended offer |
| --- | --- |
| `orbit_expansion_101_200` | ₹10, stages 101–200 |
| `orbit_expansion_201_250` | ₹10, stages 201–250 |
| `orbit_all_access_vip` | ₹30, all packs + Omega skin |

Stages unlock sequentially even after buying a pack. Product IDs must exist in the relevant provider console. Display prices should be replaced with actual localized provider metadata. Ads and purchases are intentionally unavailable by default: no simulated checkout, fabricated ad reward, or unverified entitlement is granted.

Inject `CommerceHooks` into `OrbitApp` in `main()`:

```dart
runApp(OrbitApp(
  profile: profile,
  commerce: CommerceHooks(
    purchase: billing.purchaseAndValidate, // Future<bool> Function(String)
    restore: billing.restoreVerifiedProducts, // Future<Set<String>> Function()
    rewardedContinue: ads.showAndWaitForReward, // Future<bool> Function()
  ),
));
```

These names illustrate your provider adapter; they are not extra bundled classes. Successful purchase callbacks must await provider transaction completion and receipt validation. Reward callbacks return true only upon the provider's earned-reward event. Never return true merely because an ad opened or closed. Restore returns verified product IDs. An empty restore leaves the local cache intact to handle offline/unavailable providers. Production entitlement reconciliation/revocation should separately refresh the cache from a trusted backend or store before granting paid access. Local VIP booleans alone are not proof of a purchase.

Android/iOS can use their supported IAP/ad SDKs. Windows and Web require appropriate supported providers; do not assume a mobile-only plugin works there. The single-file gameplay remains platform-neutral; provider-specific configuration, consent, backend validation and native manifests necessarily live outside `main.dart`.

## Release status

See `VALIDATION.md` for checks actually run. This is a complete playable implementation with release-oriented state handling and integration boundaries. It is **not yet a signed, monetized, store-ready release**. Before shipping, connect and sandbox-test billing/ad providers, configure store products and localized pricing, entitlement validation and restore, ad consent/privacy disclosures, app IDs/icons/signing, then run native device QA and performance profiling. A 60 FPS target cannot be certified across devices without measurements. Campaign balance and every-stage solvability need playtesting, especially the final boss.

### Android 1.1 ad placements

- Campaign counts first clears. After two new clears, **Next Stage** tries a preloaded interstitial. There is no elapsed-time requirement. If the ad cannot show, Campaign advances immediately. A completed rewarded gem ad resets that count. Two interstitials can show per app session.
- The Armory offers 25 gems per completed rewarded ad, up to three claims per UTC day. The claim count survives restarts. Verified VIP users can claim without ads and have one ad-free Endless continue per run.
- Android uses Google's sample AdMob app and ad unit IDs, which do not earn revenue. The Android app ID is in the manifest and the unit IDs are in MainActivity.kt. Before publishing with live ads, configure your own AdMob app and units and integrate the applicable consent flow. Live billing remains a provider hook.

### Android 1.1.1 sound and vibration

The Android build includes short sounds and vibration pulses for launches, hits, misses, and stage or wave clears. The speaker and vibration buttons below the playfield control them independently and remember your preferences. Sounds use Android media volume. Flutter's platform haptics remain the fallback on other targets.

### Android 1.1.2 startup

The Flutter splash holds briefly while saved progress loads, before handing off to the campaign. Version 1.1.3 uses the original Android launch resources to address the startup issue reported on 1.1.2.

### Android 1.1.4 launch compatibility

Android uses Flutter's legacy renderer for this build. The game opens before it initializes the optional audio, vibration and ad systems. Ad preloading begins on the first shot. The existing package ID, signing key and local save format support upgrades in place.

### Android 1.1.5 recovery

This build restores the Dart entry point and Android app sources from the last pre-splash release, 1.1.1. It opens the game directly after loading the local profile. The version code is higher so Android can install it over the later builds without erasing game data.

### Android 1.2.0

This version starts from the Galaxy S24 Ultra's working v1.0.0 build. It adds a Flutter-only splash, four Android sound cues loaded on demand, and a count and progress ring inside the orbit. The count decreases on a hit, not on launch. The ad SDK and customized Android launch theme are excluded. A separate recovery APK preserves the original code and uses a higher update code so it can be installed over 1.2.0 if needed.

The v1.2.0 browser edition shows a branded loading screen while Flutter starts and then the in-game splash and orbit counter. It is served under /play/ and keeps the same browser save origin. Sound cues in this release use the Android integration.

### 1.3.0 wheel Armory

Armory → Wheels includes Classic Orbit (free), Solar Forge (100 gems), Tidal Circuit (240), Violet Eclipse (480) and Prism Reactor (850). Wheel purchases are cosmetic, saved with the player's profile and charged once. Landing an arrow adds a brief visual ripple. Browser and Android saves remain separate. The optional rewarded-gem provider hook supports 25 gems per completed ad, up to three claims per UTC day. These builds have no connected rewarded-ad provider, so the Armory hides that action. The updated Android APK is 64-bit. The download page retains the older 32-bit APK and the recovery APK.

### 1.4.0 Campaign economy and Test APK

The first stage is free. A newly unlocked Campaign stage costs 5 gems the first time you choose it. Entries already paid for, attempts on the same stage, and ranges owned through an old stage pack remain free. After two first clears, advancing shows a skippable in-game VIP promotion when no ad provider is attached. Optional ad and checkout callbacks accept only verified provider results. The ₹199 VIP pass removes gem charges and ads, opens every stage, and enables all skins. A live ad network and verified production billing are not configured in these builds.

Orbit Arrow Test uses the separate Android application ID `dev.orbitarrow.orbit_arrow_overdrive.test`. It supports every stage and skin, has no entry fees or ads, and offers free Endless continues. To build the same variant, set `ORBIT_TEST_EDITION=true` for Gradle and run `flutter build apk --dart-define=ORBIT_TEST_EDITION=true`. For standard Android and web builds, omit both test options.

### 1.4.1 Campaign retry ad placement

The first three retries in a run of attempts on the same Campaign stage start immediately. The fourth and later retries run the same ad placement used for Campaign progression, with the in-game promotion as a skippable fallback. Changing stages or completing the stage ends the retry streak. VIP and Orbit Arrow Test skip the placement, Endless restarts remain unaffected, and retries do not charge gems.
