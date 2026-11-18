// Orbit Arrow: Overdrive — all application and game code in one file.
// Requires: flutter pub add shared_preferences
// Run on Android, iOS, Windows or Web with a recent stable Flutter SDK.
// No assets, dart:io, platform channels, fonts or audio packages are required.
// Payment/ad callbacks below must be connected to real platform providers.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
// Retain compatibility with Flutter versions before Material's package split.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const tau = math.pi * 2;
const ink = Color(0xFF080D1B);
const cyan = Color(0xFF49ECFF);
const gold = Color(0xFFFFD166);
const red = Color(0xFFFF4D73);
const worldNames = [
  'Neon Orbit',
  'Twin Vortex',
  'Phantom Pulse',
  'Gravity Drift',
  'Omega Overdrive',
];
const worldColors = [
  cyan,
  Color(0xFF9C8BFF),
  Color(0xFFE27DFF),
  Color(0xFF63F5B1),
  gold,
];
double wrap(double a) => (a % tau + tau) % tau;
double angleGap(double a, double b) => (wrap(a - b) + math.pi) % tau - math.pi;
Offset radial(double angle, double radius) =>
    Offset(math.cos(angle), math.sin(angle)) * radius;

const orbitTestEdition = bool.fromEnvironment('ORBIT_TEST_EDITION');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final profile = Profile(testEdition: orbitTestEdition);
  final startup = Future.wait<void>([
    profile.load(),
    Future<void>.delayed(const Duration(milliseconds: 850)),
  ]);
  runApp(OrbitApp(profile: profile, startup: startup));
}

// Verified entitlements only: the default callbacks cannot charge or grant items.
// Implement purchase with your IAP adapter and server/store receipt validation.
// Restore should return the COMPLETE set of currently verified nonconsumables.
// A rewarded-ad adapter must return true ONLY after its earned-reward callback.
class CommerceHooks {
  final Future<bool> Function(String productId) purchase;
  final Future<Set<String>> Function() restore;
  final Future<bool> Function() rewardedContinue;
  final Future<bool> Function()? rewardedGems;
  final Future<bool> Function()? campaignAd;
  const CommerceHooks({
    this.purchase = unavailablePurchase,
    this.restore = unavailableRestore,
    this.rewardedContinue = unavailableAd,
    this.rewardedGems,
    this.campaignAd,
  });
  static Future<bool> unavailablePurchase(String _) async => false;
  static Future<Set<String>> unavailableRestore() async => <String>{};
  static Future<bool> unavailableAd() async => false;
}

const vipProduct = 'orbit_all_access_vip';

// One versioned snapshot avoids inconsistent cross-key saves. A failed load
// preserves the corrupt data until the next explicit change and uses defaults.
class Profile extends ChangeNotifier {
  Profile({this.testEdition = false});
  final bool testEdition;
  bool get fullAccess => vip || testEdition;
  int enteredThrough = 1;
  int lastCampaign = 1;
  int clearsTowardAd = 0;

  bool canSelectStage(int stage) =>
      stage >= 1 && stage <= 250 && (fullAccess || stage <= unlocked);
  int stagePrice(int stage) {
    if (fullAccess || stage <= enteredThrough) return 0;
    // Preserve free entry in ranges already bought before the VIP update.
    if ((pack1 && stage >= 101 && stage <= 200) || (pack2 && stage >= 201)) {
      return 0;
    }
    return 5;
  }

  bool enterStage(int stage) {
    if (!canSelectStage(stage)) return false;
    final price = stagePrice(stage);
    if (gems < price) return false;
    gems -= price;
    if (!fullAccess) enteredThrough = math.max(enteredThrough, stage);
    lastCampaign = stage;
    unawaited(save());
    return true;
  }

  bool ownsArrow(Skin skin) => fullAccess || owned.contains(skin.id);
  bool ownsWheel(WheelSkin wheel) => fullAccess || ownedWheels.contains(wheel);

  bool equipArrow(Skin skin) {
    if (!ownsArrow(skin)) {
      if (skin.price == 0 || gems < skin.price) return false;
      gems -= skin.price;
      owned.add(skin.id);
    }
    equipped = skin.id;
    unawaited(save());
    return true;
  }

  bool get campaignAdDue => !fullAccess && clearsTowardAd >= 2;

  void recordCampaignClear(int level) {
    if (!fullAccess && (stars[level] ?? 0) == 0) {
      clearsTowardAd = math.min(2, clearsTowardAd + 1);
    }
  }

  void recordCampaignAd() {
    clearsTowardAd = 0;
    unawaited(save());
  }

  SharedPreferences? _prefs;
  int unlocked = 1, gems = 0, bestWave = 0, bestScore = 0;
  bool vip = false, pack1 = false, pack2 = false, haptics = true, sound = true;
  String equipped = 'cyber';
  Set<String> owned = {'cyber'};
  WheelSkin equippedWheel = WheelSkin.classic;
  final Set<WheelSkin> ownedWheels = {WheelSkin.classic};
  String _gemDay = '';
  int _gemClaims = 0;

  bool equipWheel(WheelSkin wheel) {
    if (!ownsWheel(wheel)) {
      if (gems < wheel.price) return false;
      gems -= wheel.price;
      ownedWheels.add(wheel);
    }
    equippedWheel = wheel;
    unawaited(save());
    return true;
  }

  int gemClaimsLeft(DateTime now) =>
      _gemDay == now.toUtc().toIso8601String().substring(0, 10)
      ? 3 - _gemClaims
      : 3;

  bool grantRewardedGems(DateTime now) {
    if (gemClaimsLeft(now) <= 0) return false;
    final day = now.toUtc().toIso8601String().substring(0, 10);
    if (_gemDay != day) {
      _gemDay = day;
      _gemClaims = 0;
    }
    _gemClaims++;
    gems += 25;
    unawaited(save());
    return true;
  }

  Map<int, int> stars = {};
  String? storageError;
  Future<void> _writes = Future<void>.value();
  static const key = 'orbit.overdrive.profile.v1';

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs!.getString(key);
      if (raw == null) return;
      final d = jsonDecode(raw) as Map<String, dynamic>;
      int integer(String k, int fallback, int max) =>
          d[k] is int ? (d[k] as int).clamp(0, max) : fallback;
      unlocked = integer('unlocked', 1, 250).clamp(1, 250);
      enteredThrough = integer(
        'enteredThrough',
        unlocked - 1,
        250,
      ).clamp(1, 250);
      lastCampaign = integer('lastCampaign', enteredThrough, 250).clamp(1, 250);
      clearsTowardAd = integer('clearsTowardAd', 0, 2);
      gems = integer('gems', 0, 1000000000);
      bestWave = integer('bestWave', 0, 1000000000);
      bestScore = integer('bestScore', 0, 1000000000);
      vip = d['vip'] == true;
      final savedWheels = d['ownedWheels'];
      if (savedWheels is List) {
        ownedWheels.addAll(
          WheelSkin.values.where((wheel) => savedWheels.contains(wheel.name)),
        );
      }
      for (final wheel in WheelSkin.values.where(ownsWheel)) {
        if (wheel.name == d['equippedWheel']) equippedWheel = wheel;
      }
      _gemDay = d['gemRewardDay'] is String ? d['gemRewardDay'] as String : '';
      _gemClaims = integer('gemRewardClaims', 0, 3);
      pack1 = d['pack1'] == true;
      pack2 = d['pack2'] == true;
      haptics = d['haptics'] != false;
      sound = d['sound'] != false;
      final known = skins.map((s) => s.id).toSet();
      if (d['owned'] is List) {
        owned.addAll(
          (d['owned'] as List).whereType<String>().where(known.contains),
        );
      }
      if (skins.any((skin) => skin.id == d['equipped'] && ownsArrow(skin))) {
        equipped = d['equipped'] as String;
      }
      if (d['stars'] is Map) {
        for (final e in (d['stars'] as Map).entries) {
          final level = int.tryParse(e.key.toString());
          if (level != null && level >= 1 && level <= 250 && e.value is int) {
            stars[level] = (e.value as int).clamp(0, 3);
          }
        }
      }
    } catch (_) {
      storageError =
          'Local save could not be loaded. Check browser/device storage.';
    }
  }

  Skin get skin =>
      skins.firstWhere((s) => s.id == equipped, orElse: () => skins.first);
  Future<void> save() {
    notifyListeners();
    final snapshot = jsonEncode({
      'version': 1,
      'unlocked': unlocked,
      'enteredThrough': enteredThrough,
      'lastCampaign': lastCampaign,
      'clearsTowardAd': clearsTowardAd,
      'gems': gems,
      'ownedWheels': ownedWheels.map((wheel) => wheel.name).toList(),
      'equippedWheel': equippedWheel.name,
      'gemRewardDay': _gemDay,
      'gemRewardClaims': _gemClaims,
      'bestWave': bestWave,
      'bestScore': bestScore,
      'vip': vip,
      'pack1': pack1,
      'pack2': pack2,
      'haptics': haptics,
      'sound': sound,
      'equipped': equipped,
      'owned': owned.toList(),
      'stars': stars.map((k, v) => MapEntry('$k', v)),
    });
    _writes = _writes.then((_) async {
      try {
        _prefs ??= await SharedPreferences.getInstance();
        if (!await _prefs!.setString(key, snapshot)) {
          throw StateError('Write rejected');
        }
        storageError = null;
      } catch (_) {
        storageError = 'Progress is in memory; local storage write failed.';
      }
      notifyListeners();
    });
    return _writes;
  }

  void applyProducts(Set<String> products) {
    vip = products.contains(vipProduct);
    if (!fullAccess) {
      if (!owned.contains(equipped)) equipped = 'cyber';
      if (!ownedWheels.contains(equippedWheel)) {
        equippedWheel = WheelSkin.classic;
      }
    }
    unawaited(save());
  }
}

enum WheelSkin {
  classic('Classic Orbit', 0, cyan, 0),
  solar('Solar Forge', 100, Color(0xFFFFAE57), 6),
  tidal('Tidal Circuit', 240, Color(0xFF63FFDB), 8),
  eclipse('Violet Eclipse', 480, Color(0xFFD69DFF), 3),
  prism('Prism Reactor', 850, Color(0xFFFF79BD), 5);

  const WheelSkin(this.label, this.price, this.tint, this.segments);
  final String label;
  final int price;
  final Color tint;
  final int segments;
}

class Skin {
  final String id, name, unlock;
  final Color color;
  final int price, shape;
  const Skin(
    this.id,
    this.name,
    this.color,
    this.price,
    this.shape,
    this.unlock,
  );
}

const skins = [
  Skin('cyber', 'Cyber Dart', cyan, 0, 0, 'Starter'),
  Skin('midas', 'Midas Talon', gold, 120, 1, '120 gems'),
  Skin('crimson', 'Crimson Kunai', red, 280, 2, '280 gems'),
  Skin('emerald', 'Emerald Viper', Color(0xFF63F5B1), 500, 3, '500 gems'),
  Skin('saw', 'Sawblade Trophy', Color(0xFFFF96C0), 0, 4, 'Clear stage 5'),
  Skin('chrono', 'Chrono Void', Color(0xFFAD91FF), 0, 5, 'Clear stage 10'),
  Skin('omega', 'Omega Sovereign', gold, 0, 6, 'Clear stage 250 or VIP'),
];

enum Motion { constant, pulse, reverse, staccato }

enum Phase { playing, won, lost }

class Stage {
  final int number, world, pins, arrows, shields;
  final double speed;
  final Motion motion;
  final bool counter, breath, phantom, drift, overclock, boss;
  Stage(int value, {bool endless = false})
    : number = value,
      world = endless ? math.min(4, (value - 1) ~/ 8) : (value - 1) ~/ 50,
      pins = value == 1 ? 2 : math.min(7, 3 + value ~/ (endless ? 6 : 40)),
      arrows = value == 1 ? 6 : math.min(13, 7 + value ~/ (endless ? 5 : 30)),
      shields = !endless && value == 250
          ? 3
          : value < 4
          ? 0
          : (value % 5 == 0 ? 2 : 1),
      speed = endless
          ? math.min(5.3, 1.7 + value * .085)
          : 1.65 + value * .009 + (value % 5 == 0 ? .3 : 0),
      motion = Motion.values[(value - 1) % 4],
      counter = endless ? value >= 9 : value >= 51,
      breath = endless ? value >= 9 : value >= 51,
      phantom = endless
          ? value >= 17
          : (value >= 101 && value <= 150 || value >= 201),
      drift = endless ? value >= 25 : value >= 151,
      overclock = value >= 5,
      boss = value % 5 == 0;
}

class Pin {
  final double angle;
  final Skin skin;
  Pin(this.angle, this.skin);
}

class RimGem {
  final double angle;
  bool taken = false;
  RimGem(this.angle);
}

class Bolt {
  final double x;
  double y;
  Bolt(this.x, this.y);
}

class Spark {
  Offset position, velocity;
  final Color color;
  double life = 1;
  final bool electric;
  Spark(this.position, this.velocity, this.color, {this.electric = false});
}

class FloatLabel {
  Offset position;
  final String text;
  final Color color;
  double life = 1;
  FloatLabel(this.position, this.text, this.color);
}

// Game coordinates always use a 420 x 760 logical arena, letterboxed by the UI.
// The Ticker drives a bounded 240 Hz fixed simulation, independent of refresh
// rate. At 60 Hz there are four small collision steps per frame. The painter
// listens directly, while the widget HUD rebuilds only on relevant events.
class OrbitGame extends ChangeNotifier {
  final Profile profile;
  final math.Random random = math.Random();
  final ValueNotifier<int> hud = ValueNotifier(0);
  OrbitGame(this.profile) {
    final saved = profile.lastCampaign;
    final resume =
        profile.canSelectStage(saved) && profile.stagePrice(saved) == 0
        ? saved
        : math.min(profile.unlocked, profile.enteredThrough);
    level = resume;
    _setup(Stage(resume));
  }
  int campaignRetries = 0;

  bool isCampaignRetry(int stage) =>
      !endless && level == stage && phase == Phase.lost;

  bool retryAdDue(int stage) =>
      !profile.fullAccess && isCampaignRetry(stage) && campaignRetries >= 3;

  late Stage stage;
  int level = 1, wave = 1, hearts = 3, score = 0, remaining = 6;
  int get arrowsToHit => stage.arrows - embeds;
  int embeds = 0, nearMisses = 0, rating = 0, reward = 0;
  bool endless = false, paused = false, backgrounded = false, continued = false;
  Phase phase = Phase.playing;
  double lastImpact = -1;
  double angle = 0, shieldAngle = 0, time = 0, clock = 0;
  double charge = 0, fever = 0, freeze = 0, shake = 0;
  double lastShot = -10, cooldown = 0, nextWave = 0, elapsedStage = 0;
  double _accumulator = 0;
  int _meterBucket = -1;
  Duration? _last;
  Bolt? bolt;
  String failure = '';
  final List<Pin> pins = [];
  final List<RimGem> rimGems = [];
  final List<Spark> sparks = [];
  final List<FloatLabel> labels = [];
  Color get color => fever > 0 ? gold : worldColors[stage.world];
  Offset get center =>
      Offset(210 + (stage.drift ? math.sin(time * .9) * 48 : 0), 285);
  double get radius => 61 + (stage.breath ? math.sin(time * 2.1) * 9 : 0);
  double get phantomAlpha => stage.phantom && time % 2.8 > 1.85 ? .12 : 1;
  double get feverFraction => fever > 0 ? fever / 3.2 : charge;
  double get shieldRadius => radius + 29;
  bool get active => !paused && !backgrounded;
  void updateHud() {
    hud.value++;
  }

  bool startCampaign(int n) {
    if (!profile.enterStage(n)) return false;
    campaignRetries = isCampaignRetry(n) ? campaignRetries + 1 : 0;
    endless = false;
    level = n;
    score = 0;
    _setup(Stage(n));
    return true;
  }

  void startEndless() {
    endless = true;
    wave = 1;
    hearts = 3;
    score = 0;
    continued = false;
    _setup(Stage(wave, endless: true));
    profile.bestWave = math.max(profile.bestWave, wave);
    unawaited(profile.save());
  }

  void _setup(Stage blueprint, {bool carryFever = false}) {
    stage = blueprint;
    phase = Phase.playing;
    angle = 0;
    shieldAngle = 0;
    time = 0;
    elapsedStage = 0;
    remaining = stage.arrows;
    embeds = 0;
    lastImpact = -1;
    nearMisses = 0;
    rating = 0;
    reward = 0;
    bolt = null;
    freeze = 0;
    cooldown = .25;
    nextWave = 0;
    shake = 0;
    if (!carryFever) {
      charge = 0;
      fever = 0;
    }
    pins.clear();
    rimGems.clear();
    sparks.clear();
    labels.clear();
    // Deterministic, asymmetric layouts; each stage starts with a short cooldown.
    final seeded = math.Random(stage.number * 71);
    for (var i = 0; i < stage.pins; i++) {
      pins.add(
        Pin(
          wrap(-math.pi + i * tau / stage.pins + seeded.nextDouble() * .14),
          skins.first,
        ),
      );
    }
    for (var i = 0; i < 3; i++) {
      rimGems.add(RimGem(i * tau / 3 + .45));
    }
    _last = null;
    _accumulator = 0;
    updateHud();
    notifyListeners();
  }

  void tick(Duration elapsed) {
    final previous = _last;
    _last = elapsed;
    if (previous == null || !active) return;
    // Discard long suspension gaps instead of replaying minutes of physics.
    final delta = ((elapsed - previous).inMicroseconds / 1000000).clamp(
      0.0,
      .1,
    );
    _accumulator += delta;
    const step = 1 / 240;
    while (_accumulator >= step) {
      _accumulator -= step;
      _step(step);
    }
    final bucket = (feverFraction * 50).floor();
    if (bucket != _meterBucket) {
      _meterBucket = bucket;
      updateHud();
    }
    notifyListeners();
  }

  void _step(double dt) {
    clock += dt;
    shake = math.max(0, shake - dt * 35);
    for (final p in sparks) {
      p.life -= dt * 2.2;
      p.position += p.velocity * dt;
      p.velocity += Offset(0, 180 * dt);
    }
    sparks.removeWhere((p) => p.life <= 0);
    for (final label in labels) {
      label.life -= dt;
      label.position -= Offset(0, 28 * dt);
    }
    labels.removeWhere((l) => l.life <= 0);
    if (freeze > 0) {
      freeze = math.max(0, freeze - dt);
      return;
    }
    if (phase != Phase.playing) return;
    if (nextWave > 0) {
      nextWave -= dt;
      if (nextWave <= 0) {
        wave++;
        profile.bestWave = math.max(profile.bestWave, wave);
        unawaited(profile.save());
        _setup(Stage(wave, endless: true), carryFever: true);
      }
      return;
    }
    cooldown = math.max(0, cooldown - dt);
    if (fever > 0) {
      fever = math.max(0, fever - dt);
    } else {
      charge = math.max(0, charge - dt * .065);
    }
    final simDt = dt * (fever > 0 ? .48 : 1);
    time += simDt;
    elapsedStage += dt;
    var speed = stage.speed;
    if (stage.overclock) speed *= 1 + math.min(4, embeds ~/ 3) * .07;
    switch (stage.motion) {
      case Motion.constant:
        break;
      case Motion.pulse:
        speed *= 1.05 + .55 * math.sin(time * 2.4);
        break;
      case Motion.reverse:
        speed *= (time ~/ 2.5).isEven ? 1 : -1;
        break;
      case Motion.staccato:
        speed *= time % 1.8 < 1.25 ? .28 : 2.15;
        break;
    }
    angle = wrap(angle + speed * simDt);
    shieldAngle = stage.counter
        ? wrap(shieldAngle - (speed.abs() * .72 + .35) * simDt)
        : angle;
    final shot = bolt;
    if (shot == null) return;
    final before = Offset(shot.x, shot.y);
    shot.y -= 1180 * simDt;
    final tip = Offset(shot.x, shot.y), tail = Offset(shot.x, shot.y + 38);
    // The same radial segments, arc spans and radii are used by the painter.
    for (var i = 0; i < pins.length; i++) {
      final a = angle + pins[i].angle;
      final p = center + radial(a, radius - 2);
      final q = center + radial(a, radius + 64);
      if (segmentDistance(tip, tail, p, q) < 6.5) {
        _crash('Clipped an embedded pin', pinIndex: i);
        return;
      }
    }
    for (var i = 0; i < stage.shields; i++) {
      final start = shieldAngle + .35 + i * tau / stage.shields;
      if (hitsArc(
        tip,
        tail,
        center,
        shieldRadius,
        start,
        stage.boss ? .48 : .36,
      )) {
        _crash('Deflected by a laser shield');
        return;
      }
    }
    for (final gem in rimGems) {
      final position = center + radial(angle + gem.angle, radius + 86);
      if (!gem.taken && pointSegment(position, before, tip) < 15) {
        gem.taken = true;
        final amount = fever > 0 ? 10 : 5;
        profile.gems += amount;
        unawaited(profile.save());
        _label(position, '+$amount 💎', gold);
        _burst(position, gold, 14);
      }
    }
    // Arrow remains vertical at its launch x even while the wheel drifts.
    final dx = shot.x - center.dx;
    if (dx.abs() <= radius) {
      final contactY = center.dy + math.sqrt(radius * radius - dx * dx);
      if (shot.y <= contactY && before.dy >= center.dy) {
        _embed(Offset(shot.x, contactY));
        return;
      }
    }
    if (shot.y < -50) _crash('Missed the drifting core');
  }

  void shoot() {
    if (!active ||
        phase != Phase.playing ||
        nextWave > 0 ||
        freeze > 0 ||
        cooldown > 0 ||
        bolt != null ||
        remaining <= 0) {
      return;
    }
    if (fever <= 0) {
      charge = (charge + (clock - lastShot < .95 ? .26 : .1)).clamp(0.0, 1.0);
      if (charge >= 1) {
        fever = 3.2;
        charge = 0;
        _label(const Offset(210, 470), 'GOLDEN FEVER · 2× GEMS', gold);
      }
    }
    lastShot = clock;
    remaining--;
    bolt = Bolt(210, 625);
    cooldown = .12;
    _haptic();
    playSound('launch');
    updateHud();
  }

  void _embed(Offset point) {
    final hitAngle = math.atan2(point.dy - center.dy, point.dx - center.dx);
    var nearest = math.pi;
    for (final pin in pins) {
      nearest = math.min(nearest, angleGap(angle + pin.angle, hitAngle).abs());
    }
    final close = nearest < .30;
    if (close) {
      nearMisses++;
      score += 15;
      _burst(point + radial(hitAngle, 35), cyan, 14, electric: true);
      _label(point + const Offset(40, 16), 'CLOSE +15', cyan);
    }
    pins.add(Pin(wrap(hitAngle - angle), profile.skin));
    bolt = null;
    embeds++;
    lastImpact = clock;
    score += fever > 0 ? 20 : 10;
    freeze = .026;
    shake = 1.8;
    _burst(point, color, 10);
    _haptic();
    playSound(remaining == 0 ? 'win' : 'hit');
    profile.bestScore = math.max(profile.bestScore, score);
    // Persist score at event boundaries, never on a frame-by-frame basis.
    unawaited(profile.save());
    if (remaining == 0) _victory();
    updateHud();
  }

  void _crash(String reason, {int? pinIndex}) {
    final position = bolt == null ? center : Offset(bolt!.x, bolt!.y);
    bolt = null;
    shake = 13;
    freeze = .13;
    _burst(position, red, 32, electric: true);
    failure = reason;
    _haptic(heavy: true);
    playSound('miss');
    if (endless) {
      hearts--;
      if (hearts > 0) {
        remaining++;
        cooldown = .65;
        if (pinIndex != null) pins.removeAt(pinIndex);
        _label(const Offset(210, 475), '$hearts HEARTS · KEEP GOING', red);
      } else {
        phase = Phase.lost;
      }
    } else {
      phase = Phase.lost;
    }
    profile.bestScore = math.max(profile.bestScore, score);
    unawaited(profile.save());
    updateHud();
  }

  void _victory() {
    reward = (stage.boss ? 45 : 15) * (fever > 0 ? 2 : 1);
    profile.gems += reward;
    _burst(center, gold, 48);
    if (endless) {
      nextWave = .85;
      freeze = .05;
      _label(const Offset(210, 470), 'WAVE $wave CLEAR · +$reward 💎', gold);
    } else {
      phase = Phase.won;
      rating = elapsedStage <= stage.arrows * 2.4
          ? 3
          : (elapsedStage <= stage.arrows * 4 ? 2 : 1);
      profile.recordCampaignClear(level);
      profile.stars[level] = math.max(profile.stars[level] ?? 0, rating);
      if (level == profile.unlocked) {
        profile.unlocked = math.min(250, level + 1);
      }
      if (level == 5) profile.owned.add('saw');
      if (level == 10) profile.owned.add('chrono');
      if (level == 250) profile.owned.add('omega');
    }
    unawaited(profile.save());
    updateHud();
  }

  void continueEndless() {
    if (!endless ||
        phase != Phase.lost ||
        (continued && !profile.testEdition)) {
      return;
    }
    continued = true;
    hearts = 3;
    remaining++;
    bolt = null;
    // Clear the firing corridor so a rewarded continue has a fair restart.
    pins.removeWhere((p) => angleGap(angle + p.angle, math.pi / 2).abs() < .5);
    phase = Phase.playing;
    cooldown = .8;
    freeze = 0;
    updateHud();
  }

  void playSound(String cue) {
    if (profile.sound &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_playAndroidSound(cue));
    }
  }

  Future<void> _playAndroidSound(String cue) async {
    try {
      await const MethodChannel(
        'orbit_arrow/sound',
      ).invokeMethod<void>('play', cue);
    } on MissingPluginException {
      // Sound is an optional Android integration.
    } on PlatformException {
      // Keep the game playable if device audio is unavailable.
    }
  }

  void _haptic({bool heavy = false}) {
    if (!profile.haptics) return;
    // Haptics are optional and never part of the simulation's success path.
    unawaited(
      (heavy ? HapticFeedback.heavyImpact() : HapticFeedback.selectionClick())
          .catchError((Object _) {}),
    );
  }

  void _burst(Offset p, Color color, int count, {bool electric = false}) {
    for (var i = 0; i < count && sparks.length < 180; i++) {
      sparks.add(
        Spark(
          p,
          radial(random.nextDouble() * tau, 45 + random.nextDouble() * 210),
          color,
          electric: electric,
        ),
      );
    }
  }

  void _label(Offset p, String text, Color color) {
    labels.add(FloatLabel(p, text, color));
  }

  void resetClock() {
    _last = null;
    _accumulator = 0;
  }

  @override
  void dispose() {
    hud.dispose();
    super.dispose();
  }
}

// Capsule-vs-capsule collision, plus exact circle intersections for laser arcs.
// The fixed substeps bound projectile travel to <5 arena pixels per step.
double pointSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final length = ab.distanceSquared;
  if (length == 0) return (p - a).distance;
  final ap = p - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / length).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
double segmentDistance(Offset a, Offset b, Offset c, Offset d) {
  final r = b - a, s = d - c;
  final cross = _cross(r, s);
  if (cross.abs() > .00001) {
    final t = _cross(c - a, s) / cross, u = _cross(c - a, r) / cross;
    if (t >= 0 && t <= 1 && u >= 0 && u <= 1) return 0;
  }
  return math.min(
    math.min(pointSegment(a, c, d), pointSegment(b, c, d)),
    math.min(pointSegment(c, a, b), pointSegment(d, a, b)),
  );
}

bool hitsArc(
  Offset a,
  Offset b,
  Offset center,
  double radius,
  double start,
  double span,
) {
  // Test both edges of the 8 px annulus and both shaft endpoints.
  bool inArc(Offset p) =>
      wrap(math.atan2(p.dy - center.dy, p.dx - center.dx) - start) <= span;
  for (final p in [a, b]) {
    if (((p - center).distance - radius).abs() < 5 && inArc(p)) return true;
  }
  final d = b - a, f = a - center;
  final aa = d.distanceSquared;
  if (aa == 0) return false;
  final bb = 2 * (f.dx * d.dx + f.dy * d.dy);
  for (final rr in [radius - 5, radius, radius + 5]) {
    final cc = f.distanceSquared - rr * rr;
    final disc = bb * bb - 4 * aa * cc;
    if (disc < 0) continue;
    for (final sign in [-1, 1]) {
      final t = (-bb + sign * math.sqrt(disc)) / (2 * aa);
      if (t >= 0 && t <= 1 && inArc(a + d * t)) return true;
    }
  }
  return false;
}

class OrbitApp extends StatelessWidget {
  final Profile profile;
  final Future<void>? startup;
  final CommerceHooks commerce;
  const OrbitApp({
    super.key,
    required this.profile,
    this.startup,
    this.commerce = const CommerceHooks(),
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: profile.testEdition ? 'Orbit Arrow Test' : 'Orbit Arrow: Overdrive',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ink,
      colorScheme: const ColorScheme.dark(
        primary: cyan,
        secondary: gold,
        surface: Color(0xFF111B30),
      ),
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: .8,
          ),
        ),
      ),
    ),
    home: FutureBuilder<void>(
      future: startup,
      builder: (context, snapshot) =>
          snapshot.connectionState == ConnectionState.waiting
          ? const OrbitSplash()
          : GameScreen(profile: profile, commerce: commerce),
    ),
  );
}

class OrbitSplash extends StatelessWidget {
  const OrbitSplash({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(radius: .85, colors: [Color(0xFF172743), ink]),
      ),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CustomPaint(
                  size: Size.square(128),
                  painter: _OrbitMark(),
                ),
                const SizedBox(height: 24),
                Text(
                  'ORBIT ARROW',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'OVERDRIVE',
                  style: TextStyle(
                    color: cyan,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 5,
                  ),
                ),
                const SizedBox(height: 32),
                const SizedBox(
                  width: 108,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: cyan,
                    semanticsLabel: 'Loading game',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _OrbitMark extends CustomPainter {
  const _OrbitMark();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 128, size.height / 128);
    const center = Offset(64, 64);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(center, 49, ring..color = const Color(0xFF345778));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 42),
      -.6,
      4.7,
      false,
      ring
        ..color = cyan
        ..strokeWidth = 4,
    );
    final arrow = Path()
      ..moveTo(64, 24)
      ..lineTo(83, 55)
      ..lineTo(69, 51)
      ..lineTo(69, 99)
      ..lineTo(59, 99)
      ..lineTo(59, 51)
      ..lineTo(45, 55)
      ..close();
    canvas.drawPath(arrow, Paint()..color = cyan);
    canvas.drawCircle(const Offset(104, 53), 5, Paint()..color = gold);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OrbitMark oldDelegate) => false;
}

class GameScreen extends StatefulWidget {
  final Profile profile;
  final CommerceHooks commerce;
  const GameScreen({super.key, required this.profile, required this.commerce});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final OrbitGame game;
  late final Ticker ticker;
  final FocusNode keyboard = FocusNode(debugLabel: 'Orbit controls');
  bool modal = false, manualPause = false, busy = false;
  Profile get profile => widget.profile;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    game = OrbitGame(profile);
    ticker = createTicker(game.tick)..start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    game.backgrounded = state != AppLifecycleState.resumed;
    game.resetClock();
    if (game.backgrounded) {
      unawaited(profile.save());
      // Require explicit resume after focus loss; no surprise deaths on return.
      manualPause = true;
      game.paused = true;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ticker.dispose();
    keyboard.dispose();
    game.dispose();
    super.dispose();
  }

  void message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void togglePause() {
    if (modal) return;
    setState(() {
      manualPause = !manualPause;
      game.paused = manualPause;
    });
    game.resetClock();
    keyboard.requestFocus();
  }

  Future<void> sheet(
    String title,
    Widget Function(BuildContext, StateSetter) content,
  ) async {
    if (modal) return;
    modal = true;
    game.paused = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
            content: SizedBox(width: 480, child: content(context, update)),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('CLOSE'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    modal = false;
    game.paused = manualPause;
    game.resetClock();
    setState(() {});
    keyboard.requestFocus();
  }

  Future<void> armory() => sheet(
    'ARROW ARMORY',
    (context, update) => DefaultTabController(
      length: 2,
      child: SizedBox(
        height: math.min(510.0, MediaQuery.sizeOf(context).height * .65),
        child: ListenableBuilder(
          listenable: profile,
          builder: (context, _) => Column(
            children: [
              Text('${profile.gems} 💎', style: const TextStyle(color: gold)),
              if (!profile.fullAccess && widget.commerce.rewardedGems != null)
                TextButton(
                  onPressed: busy || profile.gemClaimsLeft(DateTime.now()) <= 0
                      ? null
                      : () => claimArmoryGems(context, update),
                  child: Text(
                    profile.gemClaimsLeft(DateTime.now()) <= 0
                        ? 'DAILY GEM LIMIT REACHED'
                        : 'WATCH AD · +25 GEMS',
                  ),
                ),
              const TabBar(
                tabs: [
                  Tab(text: 'Arrows'),
                  Tab(text: 'Wheels'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    ListView(
                      children: [
                        for (final skin in skins)
                          _armoryItem(
                            name: skin.name,
                            hint: skin.unlock,
                            color: skin.color,
                            preview: CustomPaint(
                              size: const Size(36, 48),
                              painter: SkinPreview(skin),
                            ),
                            label: profile.equipped == skin.id
                                ? 'EQUIPPED'
                                : profile.ownsArrow(skin)
                                ? 'EQUIP'
                                : skin.price > 0
                                ? '${skin.price} 💎'
                                : 'BOSS LOCKED',
                            action:
                                profile.equipped == skin.id ||
                                    (!profile.ownsArrow(skin) &&
                                        (skin.price == 0 ||
                                            profile.gems < skin.price))
                                ? null
                                : () {
                                    profile.equipArrow(skin);
                                  },
                          ),
                      ],
                    ),
                    ListView(
                      children: [
                        for (final wheel in WheelSkin.values)
                          _armoryItem(
                            name: wheel.label,
                            hint: wheel == WheelSkin.classic
                                ? 'Starter wheel'
                                : 'Cosmetic wheel',
                            color: wheel.tint,
                            preview: CustomPaint(
                              size: const Size.square(48),
                              painter: WheelPreview(wheel),
                            ),
                            label: profile.equippedWheel == wheel
                                ? 'EQUIPPED'
                                : profile.ownsWheel(wheel)
                                ? 'EQUIP'
                                : '${wheel.price} 💎',
                            action:
                                profile.equippedWheel == wheel ||
                                    (!profile.ownsWheel(wheel) &&
                                        profile.gems < wheel.price)
                                ? null
                                : () {
                                    profile.equipWheel(wheel);
                                  },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _armoryItem({
    required String name,
    required String hint,
    required Color color,
    required Widget preview,
    required String label,
    required VoidCallback? action,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              preview,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      hint,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(onPressed: action, child: Text(label)),
          ),
        ],
      ),
    ),
  );

  Future<void> claimArmoryGems(BuildContext context, StateSetter update) async {
    final showAd = widget.commerce.rewardedGems;
    if (busy ||
        profile.fullAccess ||
        showAd == null ||
        profile.gemClaimsLeft(DateTime.now()) <= 0) {
      return;
    }
    busy = true;
    update(() {});
    try {
      if (await showAd()) {
        profile.grantRewardedGems(DateTime.now());
      } else if (mounted) {
        message('Ad unavailable or incomplete. Try again shortly.');
      }
    } catch (_) {
      if (mounted) message('Ad unavailable. Try again shortly.');
    } finally {
      busy = false;
      if (context.mounted) update(() {});
    }
  }

  Future<void> store() => sheet(
    profile.testEdition ? 'ORBIT ARROW TEST' : 'VIP PASS',
    (context, update) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            profile.testEdition
                ? 'Test edition · all 250 stages and all skins are unlocked.'
                : 'One-time ₹50 VIP pass',
          ),
          const SizedBox(height: 12),
          const Text(
            'All 250 stages open · every arrow and wheel skin · no entry fees · no ads',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy || profile.fullAccess
                ? null
                : () async {
                    busy = true;
                    update(() {});
                    try {
                      if (await widget.commerce.purchase(vipProduct)) {
                        profile.applyProducts({vipProduct});
                        message('VIP unlocked.');
                      } else {
                        message('VIP checkout is unavailable in this build.');
                      }
                    } catch (_) {
                      message('Purchase could not be completed.');
                    } finally {
                      busy = false;
                      if (context.mounted) update(() {});
                    }
                  },
            child: Text(
              profile.testEdition
                  ? 'TEST ACCESS ACTIVE'
                  : profile.vip
                  ? 'VIP ACTIVE'
                  : 'BUY VIP · ₹50',
            ),
          ),
          if (!profile.testEdition)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      busy = true;
                      update(() {});
                      try {
                        final restored = await widget.commerce.restore();
                        if (restored.contains(vipProduct)) {
                          profile.applyProducts(restored);
                          message('VIP restored.');
                        } else {
                          message('No VIP purchase could be restored.');
                        }
                      } catch (_) {
                        message('Restore is unavailable. Try again later.');
                      } finally {
                        busy = false;
                        if (context.mounted) update(() {});
                      }
                    },
              child: const Text('RESTORE VIP'),
            ),
        ],
      ),
    ),
  );

  Future<void> openStage(int stage) async {
    if (busy || modal || !profile.canSelectStage(stage)) return;
    final price = profile.stagePrice(stage);
    if (profile.gems < price) {
      message('You need 5 gems. Replay a stage or play Endless to earn more.');
      return;
    }
    final retryAd = game.retryAdDue(stage);
    final progressionAd =
        !game.endless && stage > game.level && profile.campaignAdDue;
    if (retryAd || progressionAd) {
      setState(() => busy = true);
      try {
        var shown = false;
        try {
          shown = await widget.commerce.campaignAd?.call() ?? false;
        } catch (_) {
          // Advance using the house placement if a network ad is unavailable.
        }
        if (!mounted) return;
        if (!shown && !profile.fullAccess) {
          shown =
              await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Orbit Arrow VIP'),
                  content: const Text(
                    'Orbit Arrow promotion · Unlock all stages and skins and remove ads with the ₹50 VIP pass.',
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: Text(
                        retryAd ? 'CONTINUE TO RETRY' : 'CONTINUE TO STAGE',
                      ),
                    ),
                  ],
                ),
              ) ??
              true;
        }
        if (shown && progressionAd) profile.recordCampaignAd();
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }
    if (mounted) game.startCampaign(stage);
  }

  Future<void> stages() async {
    int? selected;
    await sheet(
      '250 ORBITS · 5 WORLDS',
      (context, update) => SizedBox(
        height: math.min(510.0, MediaQuery.sizeOf(context).height * .6),
        child: ListView.builder(
          itemCount: 5,
          itemBuilder: (context, world) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '${world + 1}  ${worldNames[world].toUpperCase()}',
                  style: TextStyle(
                    color: worldColors[world],
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: List.generate(50, (index) {
                  final n = world * 50 + index + 1;
                  final available = profile.canSelectStage(n);
                  return SizedBox(
                    width: 62,
                    height: 57,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: available
                            ? worldColors[world]
                            : Colors.white30,
                      ),
                      onPressed: () {
                        if (!available) {
                          message(
                            'Clear stage ${profile.unlocked} to advance.',
                          );
                          return;
                        }
                        if (profile.gems < profile.stagePrice(n)) {
                          message('You need 5 gems to enter this stage.');
                          return;
                        }
                        selected = n;
                        Navigator.pop(context);
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            available ? '$n' : '🔒 $n',
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            profile.stagePrice(n) > 0 && available
                                ? '5 💎'
                                : '★' * (profile.stars[n] ?? 0),
                            style: const TextStyle(color: gold, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );

    if (selected case final stage?) await openStage(stage);
  }

  Future<void> rewardedContinue() async {
    if (busy || (game.continued && !profile.testEdition)) return;
    setState(() => busy = true);
    game.paused = true;
    try {
      final earned =
          profile.fullAccess || await widget.commerce.rewardedContinue();
      if (!mounted) return;
      if (earned) {
        game.continueEndless();
      } else {
        message(
          'No rewarded ad completed. Connect an ad provider to enable continues.',
        );
      }
    } catch (_) {
      message('Ad unavailable. You can restart survival.');
    } finally {
      game.paused = manualPause;
      game.resetClock();
      if (mounted) setState(() => busy = false);
    }
  }

  Widget button(String text, VoidCallback action, {Color? color}) => TextButton(
    onPressed: action,
    style: TextButton.styleFrom(
      foregroundColor: color ?? cyan,
      textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    ),
    child: Text(text),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Focus(
        focusNode: keyboard,
        autofocus: true,
        onKeyEvent: (node, event) {
          // Ignore repeat events; one press launches at most one arrow.
          if (event is KeyDownEvent && !modal) {
            if (event.logicalKey == LogicalKeyboardKey.space) {
              game.shoot();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.keyP) {
              togglePause();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 420,
              height: 760,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (_) {
                          keyboard.requestFocus();
                          game.shoot();
                        },
                        child: CustomPaint(painter: OrbitPainter(game)),
                      ),
                    ),
                  ),
                  // Pointer events in buttons never reach the playfield gesture detector.
                  Positioned(
                    top: 10,
                    left: 16,
                    right: 16,
                    child: ListenableBuilder(
                      listenable: Listenable.merge([game.hud, profile]),
                      builder: (context, _) => Column(
                        children: [
                          Row(
                            children: [
                              button(
                                game.endless
                                    ? '∞ WAVE ${game.wave}'
                                    : 'STAGE ${game.level.toString().padLeft(3, '0')}',
                                () {
                                  stages();
                                },
                              ),
                              const Spacer(),
                              Text(
                                '${profile.gems} 💎',
                                style: const TextStyle(
                                  color: gold,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Pause / resume (P)',
                                onPressed: togglePause,
                                icon: Icon(
                                  manualPause ? Icons.play_arrow : Icons.pause,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Text(
                                worldNames[game.stage.world].toUpperCase(),
                                style: TextStyle(
                                  color: game.color,
                                  fontSize: 10,
                                  letterSpacing: 2,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                game.endless
                                    ? '${'❤️' * game.hearts}${'♡' * (3 - game.hearts)}'
                                    : (game.level == 250
                                          ? 'FINAL BOSS'
                                          : game.stage.boss
                                          ? 'BOSS ORBIT'
                                          : 'PRECISION RUN'),
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (game.endless)
                            Text(
                              'BEST WAVE ${profile.bestWave}  ·  SCORE ${game.score}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 30,
                    right: 30,
                    bottom: 83,
                    child: ValueListenableBuilder<int>(
                      valueListenable: game.hud,
                      builder: (context, _, child) => IgnorePointer(
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  game.fever > 0
                                      ? 'GOLDEN FEVER · 2× GEMS'
                                      : 'RAPID FIRE → GOLDEN FEVER',
                                  style: TextStyle(
                                    color: game.fever > 0
                                        ? gold
                                        : Colors.white54,
                                    fontSize: 9,
                                    letterSpacing: 1,
                                  ),
                                ),
                                Text(
                                  '${game.arrowsToHit} LEFT',
                                  style: const TextStyle(
                                    color: cyan,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: game.feverFraction.clamp(0.0, 1.0),
                                minHeight: 4,
                                color: gold,
                                backgroundColor: Colors.white12,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'TAP / CLICK / SPACE TO LAUNCH',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    left: 10,
                    right: 10,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        button('ARMORY', () {
                          armory();
                        }),
                        button('∞ ENDLESS', () {
                          setState(() {
                            manualPause = false;
                            game.paused = false;
                            game.startEndless();
                          });
                        }),
                        button(profile.testEdition ? 'TEST' : 'VIP', () {
                          store();
                        }, color: gold),
                        if (!kIsWeb &&
                            defaultTargetPlatform == TargetPlatform.android)
                          IconButton(
                            tooltip: profile.sound
                                ? 'Mute sound'
                                : 'Enable sound',
                            onPressed: () {
                              setState(() => profile.sound = !profile.sound);
                              if (profile.sound) game.playSound('hit');
                              unawaited(profile.save());
                            },
                            icon: Icon(
                              profile.sound
                                  ? Icons.volume_up
                                  : Icons.volume_off,
                              size: 18,
                            ),
                          ),
                        IconButton(
                          tooltip: 'Toggle haptics',
                          onPressed: () {
                            setState(() => profile.haptics = !profile.haptics);
                            unawaited(profile.save());
                          },
                          icon: Icon(
                            profile.haptics
                                ? Icons.vibration
                                : Icons.phone_android,
                            size: 18,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned.fill(
                    child: ValueListenableBuilder<int>(
                      valueListenable: game.hud,
                      builder: (context, _, child) {
                        if (game.phase == Phase.playing && !manualPause) {
                          return const SizedBox.shrink();
                        }
                        return ColoredBox(
                          color: ink.withValues(alpha: .9),
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    manualPause
                                        ? Icons.pause_circle_outline
                                        : game.phase == Phase.won
                                        ? Icons.auto_awesome
                                        : Icons.crisis_alert,
                                    size: 52,
                                    color: game.phase == Phase.lost
                                        ? red
                                        : gold,
                                  ),
                                  const SizedBox(height: 20),
                                  Text(
                                    manualPause
                                        ? 'ORBIT PAUSED'
                                        : game.phase == Phase.won
                                        ? (game.level == 250
                                              ? 'OMEGA CONQUERED'
                                              : 'ORBIT LOCKED')
                                        : game.endless
                                        ? 'SURVIVAL COMPLETE'
                                        : 'DEFLECTED',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 27,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  if (!manualPause)
                                    Text(
                                      game.phase == Phase.won
                                          ? '${'★' * game.rating}${'☆' * (3 - game.rating)}\n+${game.reward} 💎  ·  ${game.score} POINTS'
                                          : '${game.failure}\n${game.endless ? 'Wave ${game.wave} · Best ${profile.bestWave}\n' : ''}${game.score} POINTS',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: gold,
                                        height: 1.7,
                                        fontSize: 16,
                                      ),
                                    ),
                                  const SizedBox(height: 22),
                                  if (manualPause) ...[
                                    FilledButton(
                                      onPressed: togglePause,
                                      child: const Text('RESUME'),
                                    ),
                                    button('STAGES', () {
                                      stages();
                                    }),
                                  ] else if (game.phase == Phase.won) ...[
                                    FilledButton(
                                      onPressed: busy
                                          ? null
                                          : () {
                                              if (game.level == 250) {
                                                stages();
                                              } else {
                                                openStage(game.level + 1);
                                              }
                                            },
                                      child: Text(
                                        game.level == 250
                                            ? 'EXPLORE ALL STAGES'
                                            : profile.stagePrice(
                                                    game.level + 1,
                                                  ) ==
                                                  0
                                            ? 'NEXT STAGE →'
                                            : 'NEXT STAGE · 5 💎',
                                      ),
                                    ),
                                    button(
                                      'REPLAY FOR STARS',
                                      () => game.startCampaign(game.level),
                                    ),
                                  ] else ...[
                                    FilledButton(
                                      onPressed: busy
                                          ? null
                                          : () => game.endless
                                                ? game.startEndless()
                                                : openStage(game.level),
                                      child: Text(
                                        game.endless
                                            ? 'RESTART SURVIVAL'
                                            : game.retryAdDue(game.level)
                                            ? 'RETRY · AD BREAK'
                                            : 'RETRY STAGE',
                                      ),
                                    ),
                                    if (game.endless &&
                                        (!game.continued ||
                                            profile.testEdition))
                                      button(
                                        busy
                                            ? 'LOADING AD…'
                                            : profile.fullAccess
                                            ? 'RESTORE 3 HEARTS'
                                            : 'WATCH AD · RESTORE 3 HEARTS',
                                        () {
                                          rewardedContinue();
                                        },
                                        color: gold,
                                      ),
                                  ],
                                  button('ARROW ARMORY', () {
                                    armory();
                                  }),
                                  button('CAMPAIGN STAGES', () {
                                    stages();
                                  }),
                                  Text(
                                    'BEST SCORE ${profile.bestScore}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.white38,
                                    ),
                                  ),
                                  if (profile.storageError != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(
                                        profile.storageError!,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: red,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

// Rendering has no state mutation, random sampling, clocks or layout-dependent
// physics. Glow is restricted to small primitives; particle count is bounded.
void _drawWheelTrim(
  Canvas canvas,
  Offset center,
  double radius,
  double angle,
  WheelSkin wheel,
  Paint paint,
) {
  if (wheel.segments == 0) return;
  final step = tau / wheel.segments;
  final rect = Rect.fromCircle(center: center, radius: radius * .79);
  paint
    ..shader = null
    ..maskFilter = null
    ..style = PaintingStyle.stroke
    ..strokeWidth = radius * .045
    ..strokeCap = StrokeCap.round
    ..color = wheel.tint.withValues(alpha: .72);
  for (var i = 0; i < wheel.segments; i++) {
    canvas.drawArc(rect, angle + i * step, step * .62, false, paint);
  }
}

class WheelPreview extends CustomPainter {
  const WheelPreview(this.wheel);
  final WheelSkin wheel;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide * .43;
    final center = size.center(Offset.zero);
    final paint = Paint()..color = const Color(0xFF15263C);
    canvas.drawCircle(center, radius, paint);
    paint
      ..color = wheel.tint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, paint);
    _drawWheelTrim(canvas, center, radius, -.35, wheel, paint);
  }

  @override
  bool shouldRepaint(WheelPreview oldDelegate) => oldDelegate.wheel != wheel;
}

class OrbitPainter extends CustomPainter {
  final OrbitGame game;
  final Paint _paint = Paint();
  final TextPainter _text = TextPainter(textDirection: TextDirection.ltr);
  OrbitPainter(this.game) : super(repaint: game);
  void line(Canvas c, Offset a, Offset b, Color color, double width) {
    _paint
      ..shader = null
      ..maskFilter = null
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    c.drawLine(a, b, _paint);
  }

  void circle(
    Canvas c,
    Offset p,
    double radius,
    Color color, {
    bool glow = false,
  }) {
    _paint
      ..shader = null
      ..style = PaintingStyle.fill
      ..color = color
      ..maskFilter = glow ? const MaskFilter.blur(BlurStyle.normal, 5) : null;
    c.drawCircle(p, radius, _paint);
    _paint.maskFilter = null;
  }

  void text(
    Canvas c,
    String value,
    Offset position,
    Color color,
    double size, {
    bool bold = false,
  }) {
    _text.text = TextSpan(
      text: value,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: bold ? FontWeight.w900 : FontWeight.w500,
        letterSpacing: 1.2,
      ),
    );
    _text.layout();
    _text.paint(c, position - Offset(_text.width / 2, _text.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = game, center = game.center, r = game.radius;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _paint
      ..shader = const RadialGradient(
        colors: [Color(0xFF14203B), ink],
        radius: .8,
        center: Alignment(0, -.3),
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, _paint);
    _paint.shader = null;
    for (var i = 0; i < 55; i++) {
      final x = (i * 137.51) % 420, y = (i * 93.17) % 760;
      circle(
        canvas,
        Offset(x, y),
        i % 3 == 0 ? 1 : .5,
        Colors.white.withValues(
          alpha: .08 + .08 * math.sin(i + g.clock * .6).abs(),
        ),
      );
    }
    for (var i = 0; i < 5; i++) {
      _paint
        ..color = g.color.withValues(alpha: .035)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawCircle(const Offset(210, 285), 130 + i * 39, _paint);
    }
    if (g.shake > 0) {
      canvas.translate(
        math.sin(g.clock * 103) * g.shake,
        math.cos(g.clock * 127) * g.shake * .6,
      );
    }
    // Thin trajectory and launch dock.
    line(
      canvas,
      const Offset(210, 492),
      const Offset(210, 620),
      Colors.white.withValues(alpha: .08),
      1,
    );
    circle(canvas, const Offset(210, 635), 23, g.color.withValues(alpha: .04));
    line(
      canvas,
      const Offset(171, 646),
      const Offset(249, 646),
      g.color.withValues(alpha: .3),
      2,
    );
    // Rim gems follow the wheel and can be collected only once per wave.
    for (final gem in g.rimGems) {
      if (gem.taken) continue;
      final p = center + radial(g.angle + gem.angle, r + 86);
      circle(canvas, p, 9, gold.withValues(alpha: .18), glow: true);
      final path = Path()
        ..moveTo(p.dx, p.dy - 7)
        ..lineTo(p.dx + 6, p.dy)
        ..lineTo(p.dx, p.dy + 7)
        ..lineTo(p.dx - 6, p.dy)
        ..close();
      _paint
        ..style = PaintingStyle.fill
        ..color = gold;
      canvas.drawPath(path, _paint);
      text(canvas, '+', p + const Offset(11, -11), gold, 10);
    }
    // All pins remain collidable during phantom phase, including at 12% opacity.
    for (final pin in g.pins) {
      final a = g.angle + pin.angle;
      final p = center + radial(a, r - 2), q = center + radial(a, r + 64);
      line(
        canvas,
        p,
        q,
        pin.skin.color.withValues(alpha: g.phantomAlpha * .75),
        2,
      );
      drawArrowHead(
        canvas,
        q,
        pin.skin,
        g.phantomAlpha,
        rotation: a + math.pi / 2,
      );
    }
    for (var i = 0; i < g.stage.shields; i++) {
      final start = g.shieldAngle + .35 + i * tau / g.stage.shields;
      final rect = Rect.fromCircle(center: center, radius: g.shieldRadius);
      _paint
        ..color = red.withValues(alpha: .22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 15;
      canvas.drawArc(rect, start, g.stage.boss ? .48 : .36, false, _paint);
      _paint
        ..color = red
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, start, g.stage.boss ? .48 : .36, false, _paint);
      circle(canvas, center + radial(start, g.shieldRadius), 4, Colors.white);
    }
    final wheel = g.profile.equippedWheel;
    final trim = wheel == WheelSkin.classic ? g.color : wheel.tint;
    final pulse = (g.clock - g.lastImpact) / .26;
    if (g.lastImpact >= 0 && pulse < 1) {
      _paint
        ..shader = null
        ..maskFilter = null
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * (1 - pulse)
        ..color = trim.withValues(alpha: .48 * (1 - pulse));
      canvas.drawCircle(center, r + 5 + pulse * 24, _paint);
    }
    circle(canvas, center, r + 5, trim.withValues(alpha: .15), glow: true);
    _paint
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: [const Color(0xFF263953), const Color(0xFF101A2E)],
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, _paint);
    _paint.shader = null;
    _paint
      ..style = PaintingStyle.stroke
      ..color = trim
      ..strokeWidth = 2;
    canvas.drawCircle(center, r, _paint);
    _paint
      ..color = trim.withValues(alpha: .22)
      ..strokeWidth = 1;
    canvas.drawCircle(center, r - 9, _paint);
    _drawWheelTrim(canvas, center, r, g.angle, wheel, _paint);
    if (g.embeds > 0) {
      _paint
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = g.color.withValues(alpha: .8);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r - 9),
        -math.pi / 2,
        tau * g.embeds / g.stage.arrows,
        false,
        _paint,
      );
    }
    for (var i = 0; i < 12; i++) {
      final a = g.angle + i * tau / 12;
      line(
        canvas,
        center + radial(a, r - 6),
        center + radial(a, r - 2),
        g.color.withValues(alpha: .6),
        2,
      );
    }
    text(
      canvas,
      '${g.arrowsToHit}',
      center - const Offset(0, 4),
      Colors.white,
      32,
      bold: true,
    );
    text(canvas, 'ARROWS LEFT', center + const Offset(0, 24), g.color, 8);
    final motionName = switch (g.stage.motion) {
      Motion.constant => 'CONSTANT',
      Motion.pulse => 'PULSE',
      Motion.reverse => 'FULL-FLIP REVERSE',
      Motion.staccato => 'STACCATO',
    };
    final warning = g.stage.motion == Motion.reverse && g.time % 2.5 > 2.08;
    text(
      canvas,
      warning ? '↔ REVERSAL INCOMING' : motionName,
      const Offset(210, 115),
      warning ? red : Colors.white38,
      9,
    );
    if (g.stage.phantom) {
      text(
        canvas,
        'PHANTOM PINS · ALWAYS SOLID',
        const Offset(210, 452),
        Colors.white30,
        8,
      );
    }
    if (g.bolt != null) {
      final p = Offset(g.bolt!.x, g.bolt!.y);
      line(canvas, p, p + const Offset(0, 38), g.color, 2.2);
      drawArrowHead(canvas, p, g.profile.skin, 1);
    } else if (g.remaining > 0 && g.phase == Phase.playing && g.nextWave <= 0) {
      line(
        canvas,
        const Offset(210, 606),
        const Offset(210, 635),
        g.color,
        2.2,
      );
      drawArrowHead(canvas, const Offset(210, 606), g.profile.skin, 1);
    }
    // Conveyor ammo display, always inside the fixed logical playfield.
    for (var i = 0; i < g.stage.arrows; i++) {
      final x = 210 + (i - (g.stage.arrows - 1) / 2) * 13;
      line(
        canvas,
        Offset(x, 571),
        Offset(x, 581),
        i < g.remaining ? g.color.withValues(alpha: .8) : Colors.white12,
        3,
      );
    }
    for (final spark in g.sparks) {
      final color = spark.color.withValues(alpha: spark.life.clamp(0.0, 1.0));
      if (spark.electric) {
        final p = spark.position;
        final tangent = spark.velocity * .045;
        line(canvas, p - tangent, p + Offset(2, -5), color, 1.5);
        line(canvas, p + Offset(2, -5), p + tangent, color, 1.5);
      } else {
        circle(canvas, spark.position, 2.4 * spark.life, color);
      }
    }
    for (final label in g.labels) {
      text(
        canvas,
        label.text,
        label.position,
        label.color.withValues(alpha: label.life.clamp(0.0, 1.0)),
        11,
        bold: true,
      );
    }
    if (g.fever > 0) {
      _paint
        ..style = PaintingStyle.stroke
        ..color = gold.withValues(alpha: .22)
        ..strokeWidth = 3;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(2, 2, 416, 756),
          const Radius.circular(22),
        ),
        _paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant OrbitPainter oldDelegate) =>
      oldDelegate.game != game;
}

// Seven distinct small silhouettes, shared by the armory and arena.
void drawArrowHead(
  Canvas c,
  Offset position,
  Skin skin,
  double alpha, {
  double rotation = 0,
}) {
  c.save();
  c.translate(position.dx, position.dy);
  c.rotate(rotation);
  final paint = Paint()..color = skin.color.withValues(alpha: alpha);
  c.drawCircle(
    Offset.zero,
    8,
    Paint()
      ..color = skin.color.withValues(alpha: alpha * .22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
  );
  final path = Path();
  switch (skin.shape) {
    case 0:
      path
        ..moveTo(0, -7)
        ..lineTo(5, 5)
        ..lineTo(0, 2)
        ..lineTo(-5, 5)
        ..close();
      c.drawPath(path, paint);
      break;
    case 1:
      path
        ..moveTo(0, -8)
        ..lineTo(5, 0)
        ..lineTo(0, 7)
        ..lineTo(-5, 0)
        ..close();
      c.drawPath(path, paint);
      break;
    case 2:
      path
        ..moveTo(0, -10)
        ..lineTo(4, 3)
        ..lineTo(0, 8)
        ..lineTo(-4, 3)
        ..close();
      c.drawPath(path, paint);
      break;
    case 3:
      for (var i = 0; i < 6; i++) {
        final p = radial(i * tau / 6 - math.pi / 2, 6);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      c.drawPath(path, paint);
      break;
    case 4:
      for (var i = 0; i < 16; i++) {
        final p = radial(i * tau / 16, i.isEven ? 8 : 4);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      c.drawPath(path, paint);
      break;
    case 5:
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      c.drawCircle(Offset.zero, 6, paint);
      break;
    default:
      path
        ..moveTo(-7, 5)
        ..lineTo(-7, -4)
        ..lineTo(-3, 0)
        ..lineTo(0, -9)
        ..lineTo(3, 0)
        ..lineTo(7, -4)
        ..lineTo(7, 5)
        ..close();
      c.drawPath(path, paint);
  }
  c.drawCircle(
    Offset.zero,
    1.7,
    Paint()..color = Colors.white.withValues(alpha: alpha),
  );
  c.restore();
}

class SkinPreview extends CustomPainter {
  final Skin skin;
  SkinPreview(this.skin);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(size.width / 2, 12),
      Offset(size.width / 2, 42),
      Paint()
        ..color = skin.color
        ..strokeWidth = 2,
    );
    drawArrowHead(canvas, Offset(size.width / 2, 12), skin, 1);
  }

  @override
  bool shouldRepaint(covariant SkinPreview oldDelegate) =>
      skin != oldDelegate.skin;
}
