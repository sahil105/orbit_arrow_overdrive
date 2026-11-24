import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
// Retain compatibility with Flutter versions before Material's package split.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orbit_arrow_overdrive/main.dart';

void advance(OrbitGame game, double seconds, {int fps = 60, double from = 0}) {
  game.tick(Duration(microseconds: (from * 1000000).round()));
  for (var i = 1; i <= (seconds * fps).round(); i++) {
    game.tick(Duration(microseconds: ((from + i / fps) * 1000000).round()));
  }
}

Future<Profile> profile() async {
  final p = Profile();
  await p.load();
  p.haptics = false;
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('250 finite stage blueprints and all final-boss hazards', () {
    for (var n = 1; n <= 250; n++) {
      final s = Stage(n);
      expect(s.world, (n - 1) ~/ 50);
      expect(s.speed.isFinite, true);
      expect(s.arrows, inInclusiveRange(6, 13));
    }
    final boss = Stage(250);
    expect([
      boss.counter,
      boss.breath,
      boss.phantom,
      boss.drift,
      boss.overclock,
      boss.boss,
    ], everyElement(true));
    expect(boss.shields, 3);
    expect(Stage(101).phantom, true);
    expect(Stage(151).drift, true);
    expect(Stage(1000000, endless: true).speed, lessThanOrEqualTo(5.3));
  });
  test('motion is consistent at 30/60/120 Hz', () async {
    final p = await profile();
    p.unlocked = 250;
    p.vip = true;
    for (final n in [1, 2, 3, 4, 201, 250]) {
      final angles = <double>[];
      for (final fps in [30, 60, 120]) {
        final game = OrbitGame(p)..startCampaign(n);
        advance(game, 4, fps: fps);
        angles.add(game.angle);
        game.dispose();
      }
      expect(angles[0], closeTo(angles[1], .025));
      expect(angles[1], closeTo(angles[2], .025));
    }
  });
  test('startup resumes the last paid stage without spending gems', () async {
    final p = await profile();
    p.unlocked = 101;
    p.enteredThrough = 100;
    p.lastCampaign = 101;
    p.gems = 5;
    final game = OrbitGame(p);
    expect(game.level, 100);
    expect(p.gems, 5);
    game.dispose();
  });

  test('stage entry charges once and preserves existing access', () async {
    final p = await profile();
    p.unlocked = 2;
    expect(p.enterStage(3), isFalse);
    expect(p.enterStage(2), isFalse);
    p.gems = 15;
    expect(p.enterStage(2), isTrue);
    expect(p.gems, 10);
    expect(p.enterStage(2), isTrue);
    expect(p.gems, 10);
    await p.save();
    final loaded = await profile();
    expect(loaded.stagePrice(2), 0);
    expect(loaded.lastCampaign, 2);
    p.pack1 = true;
    expect(p.stagePrice(101), 0);
  });

  test(
    'two first clears qualify for an ad, while VIP and test skip it',
    () async {
      final p = await profile();
      p.recordCampaignClear(1);
      p.stars[1] = 1;
      p.recordCampaignClear(1);
      expect(p.campaignAdDue, isFalse);
      p.recordCampaignClear(2);
      expect(p.campaignAdDue, isTrue);
      p.applyProducts({vipProduct});
      expect(p.campaignAdDue, isFalse);
      expect(p.enterStage(250), isTrue);
      expect(p.equipArrow(skins.last), isTrue);
      expect(p.equipWheel(WheelSkin.prism), isTrue);
      expect(p.gems, 0);

      final sandbox = Profile(testEdition: true)..clearsTowardAd = 2;
      expect(sandbox.enterStage(250), isTrue);
      expect(sandbox.equipWheel(WheelSkin.prism), isTrue);
      expect(sandbox.equipArrow(skins.last), isTrue);
      expect(sandbox.campaignAdDue, isFalse);
      expect(sandbox.gems, 0);
      await sandbox.save();
    },
  );

  test('geometry detects crossing pins and wrapped laser arcs', () {
    expect(
      segmentDistance(
        const Offset(0, 0),
        const Offset(10, 0),
        const Offset(5, -5),
        const Offset(5, 5),
      ),
      0,
    );
    expect(
      pointSegment(const Offset(5, 4), Offset.zero, const Offset(10, 0)),
      4,
    );
    expect(
      hitsArc(
        const Offset(0, 80),
        const Offset(0, 120),
        Offset.zero,
        100,
        1.4,
        .4,
      ),
      true,
    );
    expect(
      hitsArc(
        const Offset(0, 80),
        const Offset(0, 120),
        Offset.zero,
        100,
        3,
        .4,
      ),
      false,
    );
    expect(
      hitsArc(
        const Offset(80, 0),
        const Offset(120, 0),
        Offset.zero,
        100,
        tau - .2,
        .4,
      ),
      true,
    );
  });
  test(
    'arrow embeds, awards stars, unlocks stage, saves and freezes on win',
    () async {
      final p = await profile();
      final game = OrbitGame(p);
      game.pins.clear();
      game.remaining = 1;
      game.cooldown = 0;
      game.shoot();
      advance(game, .6);
      expect(game.phase, Phase.won);
      expect(p.unlocked, 2);
      expect(p.stars[1], 3);
      expect(p.gems, greaterThan(0));
      final before = game.angle;
      advance(game, 1, from: .6);
      expect(game.angle, before);
      await p.save();
      final reloaded = await profile();
      expect(reloaded.unlocked, 2);
      expect(reloaded.stars[1], 3);
      game.dispose();
    },
  );
  test(
    'laser shields cause a loss instead of silently allowing an embed',
    () async {
      final game = OrbitGame(await profile());
      game.stage = Stage(4);
      game.pins.clear();
      // Shaft already crossing a shield centered on the lower radial lane.
      game.shieldAngle = math.pi / 2 - .5;
      game.angle = game.shieldAngle;
      game.bolt = Bolt(210, game.center.dy + game.shieldRadius - 2);
      advance(game, .02);
      expect(game.phase, Phase.lost);
      expect(game.failure, contains('shield'));
      game.dispose();
    },
  );
  test('phantom pins stay solid at 12 percent opacity', () async {
    final p = await profile();
    p.vip = true;
    p.unlocked = 250;
    final game = OrbitGame(p)..startCampaign(101);
    game.time = 2;
    game.angle = 0;
    game.pins.clear();
    game.pins.add(Pin(math.pi / 2, skins.first));
    game.bolt = Bolt(game.center.dx, game.center.dy + game.radius + 35);
    expect(game.phantomAlpha, .12);
    advance(game, .02);
    expect(game.phase, Phase.lost);
    game.dispose();
  });
  test('endless advances without modal, retains hearts and charge', () async {
    final game = OrbitGame(await profile())..startEndless();
    game.pins.clear();
    game.remaining = 1;
    game.cooldown = 0;
    game.shoot();
    advance(game, 1.5);
    expect(game.wave, 2);
    expect(game.phase, Phase.playing);
    expect(game.hearts, 3);
    expect(game.profile.bestWave, 2);
    game.dispose();
  });
  test(
    'three crashes end survival; one earned continue restores 3 hearts',
    () async {
      final game = OrbitGame(await profile())..startEndless();
      for (var i = 0; i < 3; i++) {
        game.stage = Stage(1);
        game.angle = 0;
        game.pins.clear();
        game.freeze = 0;
        game.pins.add(Pin(math.pi / 2, skins.first));
        game.bolt = Bolt(210, game.center.dy + game.radius + 35);
        game.resetClock();
        advance(game, .02);
        expect(game.hearts, 2 - i);
      }
      expect(game.phase, Phase.lost);
      game.continueEndless();
      expect(game.hearts, 3);
      expect(game.continued, true);
      expect(game.phase, Phase.playing);
      game.phase = Phase.lost;
      game.hearts = 0;
      game.continueEndless();
      expect(game.hearts, 0);
      game.dispose();
    },
  );
  test('rapid shots trigger fever; world slows and fever pays twice', () async {
    final game = OrbitGame(await profile());
    for (var i = 0; i < 5; i++) {
      game.cooldown = 0;
      game.bolt = null;
      game.shoot();
      game.clock += .4;
    }
    expect(game.fever, greaterThan(0));
    game.pins.clear();
    game.bolt = null;
    game.cooldown = 0;
    game.remaining = 1;
    game.shoot();
    game.resetClock();
    advance(game, 1);
    expect(game.phase, Phase.won);
    expect(game.reward, 30);
    expect(game.profile.gems, greaterThanOrEqualTo(30));
    game.dispose();
  });
  test('pause and suspension never advance simulation', () async {
    final game = OrbitGame(await profile());
    advance(game, 1);
    final before = game.angle;
    game.paused = true;
    advance(game, 30, from: 1);
    expect(game.angle, before);
    game.paused = false;
    game.resetClock();
    game.tick(const Duration(hours: 2));
    expect(game.angle, before);
    game.dispose();
  });
  test('progression gates, boss skins and billing defaults', () async {
    final p = await profile();
    final game = OrbitGame(p);
    game.startCampaign(200);
    expect(game.level, 1);
    p.unlocked = 250;
    game.startCampaign(101);
    expect(game.level, 1);
    p.pack1 = true;
    game.startCampaign(101);
    expect(game.level, 101);
    game.startCampaign(5);
    game.pins.clear();
    game.stage = Stage(1);
    game.remaining = 1;
    game.cooldown = 0;
    game.shoot();
    advance(game, .6);
    expect(p.owned, contains('saw'));
    expect(await const CommerceHooks().purchase(vipProduct), false);
    expect(await const CommerceHooks().rewardedContinue(), false);
    game.dispose();
  });
  test(
    'snapshot roundtrip, invalid save recovery and serialized writes',
    () async {
      final p = await profile();
      p.gems = 350;
      p.unlocked = 105;
      p.vip = true;
      p.stars[104] = 2;
      p.owned.add('midas');
      p.equipped = 'midas';
      final first = p.save();
      p.gems = 360;
      final last = p.save();
      await Future.wait([first, last]);
      final saved = await profile();
      expect(saved.gems, 360);
      expect(saved.vip, true);
      expect(saved.ownsArrow(skins.last), isTrue);
      expect(saved.equipped, 'midas');
      expect(saved.stars[104], 2);
      SharedPreferences.setMockInitialValues({Profile.key: '{broken'});
      final broken = await profile();
      expect(broken.unlocked, 1);
      expect(broken.storageError, isNotNull);
      SharedPreferences.setMockInitialValues({
        Profile.key: jsonEncode({
          'unlocked': 9999,
          'gems': -20,
          'owned': ['nonexistent'],
        }),
      });
      final sanitized = await profile();
      expect(sanitized.unlocked, 250);
      expect(sanitized.gems, 0);
      expect(sanitized.owned, {'cyber'});
    },
  );
  test(
    'arrows left counts targets still to hit, including the flying arrow',
    () async {
      final game = OrbitGame(await profile());
      addTearDown(game.dispose);
      game.pins.clear();
      game.cooldown = 0;
      expect(game.arrowsToHit, 6);
      game.shoot();
      expect(game.remaining, 5);
      expect(game.arrowsToHit, 6);
      advance(game, .6);
      expect(game.arrowsToHit, 5);
    },
  );

  testWidgets('splash waits for the saved profile before opening the game', (
    tester,
  ) async {
    final p = Profile();
    final ready = Completer<void>();
    await tester.pumpWidget(OrbitApp(profile: p, startup: ready.future));
    expect(find.byType(OrbitSplash), findsOneWidget);
    expect(find.byType(GameScreen), findsNothing);
    p.unlocked = 3;
    p.enteredThrough = 3;
    p.lastCampaign = 3;
    ready.complete();
    await tester.pump();
    expect(find.byType(OrbitSplash), findsNothing);
    expect(find.text('STAGE 003'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'wheel purchases persist and equipping twice charges only once',
    () async {
      final p = await profile();
      expect(p.equipWheel(WheelSkin.solar), isFalse);
      p.gems = 125;
      expect(p.equipWheel(WheelSkin.solar), isTrue);
      expect(p.gems, 25);
      expect(p.equipWheel(WheelSkin.classic), isTrue);
      expect(p.equipWheel(WheelSkin.solar), isTrue);
      expect(p.gems, 25);
      await p.save();
      final reloaded = await profile();
      expect(reloaded.equippedWheel, WheelSkin.solar);
      expect(reloaded.ownedWheels, {WheelSkin.classic, WheelSkin.solar});
    },
  );

  testWidgets('stage selection shows the due promotion before charging entry', (
    tester,
  ) async {
    final p = Profile()
      ..gems = 10
      ..unlocked = 2
      ..clearsTowardAd = 2;
    await tester.pumpWidget(OrbitApp(profile: p));
    await tester.tap(find.text('STAGE 001'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('CONTINUE TO STAGE'), findsOneWidget);
    expect(p.gems, 10);
    await tester.tap(find.text('CONTINUE TO STAGE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('STAGE 002'), findsOneWidget);
    expect(p.gems, 5);
    expect(p.clearsTowardAd, 0);
    await tester.pumpWidget(const SizedBox());
    await p.save();
  });

  testWidgets('the fourth same-stage retry opens the ad placement', (
    tester,
  ) async {
    final p = Profile();
    await tester.pumpWidget(OrbitApp(profile: p));
    final game = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<OrbitPainter>()
        .single
        .game;
    for (var retry = 1; retry <= 4; retry++) {
      game.phase = Phase.lost;
      game.updateHud();
      await tester.pump();
      await tester.tap(
        find.text(retry <= 3 ? 'RETRY STAGE' : 'RETRY · AD BREAK'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (retry <= 3) {
        expect(find.text('CONTINUE TO RETRY'), findsNothing);
        expect(game.phase, Phase.playing);
      } else {
        expect(find.text('CONTINUE TO RETRY'), findsOneWidget);
        expect(game.phase, Phase.lost);
        await tester.tap(find.text('CONTINUE TO RETRY'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(game.phase, Phase.playing);
      }
      expect(p.gems, 0);
      expect(game.campaignRetries, retry);
    }
    game.phase = Phase.lost;
    for (var retry = 5; retry <= 16; retry++) {
      game.campaignRetries = retry - 1;
      expect(game.retryAdDue(1), retry % 4 == 0, reason: 'Retry $retry');
    }
    p.vip = true;
    expect(game.retryAdDue(1), isFalse);
    expect(game.startCampaign(2), isTrue);
    expect(game.campaignRetries, 0);
    await tester.pumpWidget(const SizedBox());
    await p.save();
  });

  testWidgets('Armory cannot open during a pending retry ad', (tester) async {
    final p = Profile();
    final ad = Completer<bool>();
    await tester.pumpWidget(
      OrbitApp(
        profile: p,
        commerce: CommerceHooks(campaignAd: () => ad.future),
      ),
    );
    final game = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<OrbitPainter>()
        .single
        .game;
    game.phase = Phase.lost;
    game.campaignRetries = 3;
    game.updateHud();
    await tester.pump();

    await tester.tap(find.text('RETRY · AD BREAK'));
    await tester.tap(find.text('ARROW ARMORY'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);

    ad.complete(true);
    await tester.pump();
    expect(game.phase, Phase.playing);
    await tester.tap(find.text('ARMORY'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('CLOSE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await p.save();
  });

  testWidgets('eighth failure offers a skip that requires an earned reward', (
    tester,
  ) async {
    final p = Profile();
    var earned = false;
    await tester.pumpWidget(
      OrbitApp(
        profile: p,
        commerce: CommerceHooks(rewardedStageSkip: () async => earned),
      ),
    );
    final game = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<OrbitPainter>()
        .single
        .game;
    game.phase = Phase.lost;
    game.campaignRetries = 6;
    game.updateHud();
    await tester.pump();
    final skip = find.text('WATCH AD · SKIP STAGE');
    expect(skip, findsNothing);
    game.campaignRetries = 7;
    game.updateHud();
    await tester.pump();
    expect(find.text('RETRY STAGE'), findsOneWidget);
    await tester.tap(skip);
    await tester.pump();
    expect(game.level, 1);
    expect(p.unlocked, 1);
    earned = true;
    await tester.tap(skip);
    await tester.pump();
    expect(game.level, 2);
    expect(game.phase, Phase.playing);
    expect(p.stars[1], isNull);
    await tester.pumpWidget(const SizedBox());
    await p.save();
  });

  test('stage skips persist for a UTC day and never count as clears', () async {
    final p = await profile();
    p.unlocked = 3;
    p.gems = 20;
    final day = DateTime.utc(2026, 11, 21);
    expect(p.skipStage(2, day), isFalse);
    expect(p.skipStage(3, day), isTrue);
    expect(p.unlocked, 4);
    expect(p.stagePrice(4), 0);
    expect(p.stars[3], isNull);
    expect(p.clearsTowardAd, 0);
    expect(p.gems, 20);
    await p.save();

    final reloaded = await profile();
    expect(reloaded.lastCampaign, 4);
    expect(reloaded.skipStage(4, day), isFalse);
    final nextDay = day.add(const Duration(days: 1));
    expect(reloaded.skipStage(4, nextDay), isTrue);
    expect(
      reloaded.canSkipStage(5, nextDay.add(const Duration(days: 1))),
      isFalse,
    );
  });

  test('premium cosmetics charge once and Royal Comet requires VIP', () async {
    final p = await profile();
    final nova = skins.firstWhere((skin) => skin.id == 'nova');
    final royal = skins.firstWhere((skin) => skin.id == 'royal');
    p.gems = 3000;
    expect(p.equipArrow(royal), isFalse);
    expect(p.equipArrow(nova), isTrue);
    expect(p.equipWheel(WheelSkin.singularity), isTrue);
    expect(p.gems, 0);
    await p.save();
    final reloaded = await profile();
    expect(reloaded.equipped, nova.id);
    expect(reloaded.equipArrow(nova), isTrue);
    expect(reloaded.equippedWheel, WheelSkin.singularity);
    expect(reloaded.equipWheel(WheelSkin.singularity), isTrue);
    reloaded.applyProducts({vipProduct});
    expect(reloaded.equipArrow(royal), isTrue);
    expect(reloaded.gems, 0);
    reloaded.applyProducts({});
    expect(reloaded.equipped, 'cyber');
    await reloaded.save();
  });

  testWidgets('main gem ad rewards only completed ads and caps daily claims', (
    tester,
  ) async {
    final p = Profile();
    var earned = false;
    var requests = 0;
    await tester.pumpWidget(
      OrbitApp(
        profile: p,
        commerce: CommerceHooks(
          rewardedGems: () async {
            requests++;
            return earned;
          },
        ),
      ),
    );
    final button = find.text('WATCH AD · +25 GEMS');
    expect(find.text('10 left today'), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(p.gems, 0);
    earned = true;
    for (var claim = 1; claim <= 10; claim++) {
      await tester.tap(button);
      await tester.pump();
      expect(p.gems, claim * 25);
      expect(find.text('+25'), findsOneWidget);
      expect(find.text('${p.gems} 💎'), findsOneWidget);
    }
    expect(requests, 11);
    expect(button, findsNothing);
    expect(find.text('DAILY GEM LIMIT REACHED'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await p.save();
    final reloaded = await profile();
    expect(reloaded.gems, 250);
    expect(reloaded.gemClaimsLeft(DateTime.now()), 0);
  });

  testWidgets('responsive UI, spacebar, pause, armory, stage grid and store', (
    tester,
  ) async {
    final p = await profile();
    await tester.binding.setSurfaceSize(const Size(320, 568));
    await tester.pumpWidget(OrbitApp(profile: p));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(find.text('ORBIT PAUSED'), findsOneWidget);
    await tester.tap(find.text('RESUME'));
    await tester.pump();
    await tester.tap(find.text('ARMORY'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('ARROW ARMORY'), findsOneWidget);
    expect(find.text('WATCH AD · +25 GEMS'), findsNothing);
    p.gems = 125;
    await p.save();
    await tester.tap(find.text('Wheels'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Solar Forge'), findsOneWidget);
    await tester.ensureVisible(find.text('100 💎'));
    await tester.pump();
    await tester.tap(find.text('100 💎'));
    await tester.pump();
    expect(p.equippedWheel, WheelSkin.solar);
    expect(p.gems, 25);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('CLOSE'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('VIP'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('VIP PASS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('CLOSE'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('STAGE 001'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('250 ORBITS · 5 WORLDS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('CLOSE'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
