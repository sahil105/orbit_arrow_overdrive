import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbit_arrow_overdrive/main.dart';

const frameMicros = 12500;

class AuditProfile extends Profile {
  AuditProfile() : super(testEdition: true) {
    haptics = false;
    sound = false;
  }

  @override
  Future<void> save() async {}
}

Duration timestamp(int frame) => Duration(microseconds: frame * frameMicros);

OrbitGame newGame(int level) {
  final game = OrbitGame(AuditProfile())..startCampaign(level);
  game.tick(Duration.zero);
  return game;
}

// Copy between shots. Visual particles and the profile economy do not affect
// collision geometry. Each candidate is evaluated with OrbitGame.tick.
OrbitGame fork(OrbitGame game, int frame) {
  return newGame(game.level)
    ..clock = game.clock
    ..time = game.time
    ..elapsedStage = game.elapsedStage
    ..angle = game.angle
    ..shieldAngle = game.shieldAngle
    ..freeze = game.freeze
    ..cooldown = game.cooldown
    ..charge = game.charge
    ..fever = game.fever
    ..lastShot = game.lastShot
    ..embeds = game.embeds
    ..remaining = game.remaining
    ..pins.replaceRange(0, game.stage.pins, game.pins)
    ..resetClock()
    ..tick(timestamp(frame));
}

List<int>? search(int level, Random random, int attempt) {
  var game = newGame(level);
  var frame = 0;
  final shots = <int>[];
  try {
    while (game.phase == Phase.playing) {
      final start = frame;
      final delay = attempt == 0 ? 0 : random.nextInt(101);
      OrbitGame? next;
      while (frame - start < 1600) {
        if (frame - start >= delay && game.cooldown <= 0 && game.freeze <= 0) {
          final candidate = fork(game, frame)..shoot();
          var landingFrame = frame;
          while (candidate.bolt != null) {
            candidate.tick(timestamp(++landingFrame));
          }
          if (candidate.phase != Phase.lost &&
              candidate.embeds == game.embeds + 1) {
            shots.add(frame);
            frame = landingFrame;
            next = candidate;
            break;
          }
          candidate.dispose();
        }
        game.tick(timestamp(++frame));
      }
      if (next == null) return null;
      game.dispose();
      game = next;
    }
    return game.phase == Phase.won ? shots : null;
  } finally {
    game.dispose();
  }
}

bool verifies(int level, List<int> shots) {
  final game = newGame(level);
  var frame = 0;
  try {
    for (final shot in shots) {
      while (frame < shot) {
        game.tick(timestamp(++frame));
      }
      game.shoot();
      if (game.bolt == null) return false;
    }
    while (game.bolt != null) {
      game.tick(timestamp(++frame));
    }
    return game.phase == Phase.won && game.embeds == game.stage.arrows;
  } finally {
    game.dispose();
  }
}

void main() {
  test('find and replay a winning timing sequence for every stage', () {
    final stages = <String, List<int>>{};
    final missing = <int>[];
    for (var level = 1; level <= 250; level++) {
      final random = Random(level);
      for (var attempt = 0; attempt < 16; attempt++) {
        final shots = search(level, random, attempt);
        if (shots != null && verifies(level, shots)) {
          stages['$level'] = shots;
          break;
        }
      }
      if (!stages.containsKey('$level')) missing.add(level);
    }
    File('tool/campaign_clear_timings.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'frameMicros': frameMicros, 'stages': stages, 'unverifiedStages': missing})}\n',
    );
    expect(missing, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 12)));
}
