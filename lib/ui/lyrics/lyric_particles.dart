import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// "Particle effect in lyrics" — Apple-Music-style sparkles that drift
/// off the highlighted (active) lyric line.
///
/// Look: quiet between lines, then a dense fan of rising, twinkling
/// embers every time the highlight changes — like the shimmer that
/// lifts off each sung line in Apple Music karaoke. Bursts spread
/// horizontally across the line via [burstWidth] so they read as a
/// ribbon of sparks rather than a single point.
///
/// Performance contract:
/// - One [CustomPainter] inside a [RepaintBoundary]; zero widget
///   rebuilds per frame — it is driven by a [Listenable] clock whose
///   `.value` is elapsed seconds (an [Animation<double>] or a
///   [ValueListenable<double>] both work).
/// - Emission is event-driven (bursts on highlight change) plus a low
///   ambient cadence, hard-capped at [LyricParticleField.maxCount], so
///   cost stays O(cap) no matter how many syllables get sung.
/// - Each particle is three `drawCircle`s sharing one Paint — no
///   shaders, no per-particle saveLayer, no blur filters. Cheap on
///   Impeller and ANGLE alike.
/// - When [enabled] is false nothing mounts and listeners do no work:
///   the effect costs literally zero while off.
///
/// Pure presentation: never touches playback state, lyric data or the
/// layout of the text itself.
class WaveLyricParticles extends StatefulWidget {
  /// Clock driving the animation; `.value` must be elapsed seconds.
  final Listenable clock;

  /// Notifier for the active lyric line index. Every change emits a
  /// fresh sparkle burst anchored at [anchor]; constant values idle
  /// with ambient particles only.
  final ValueListenable<int>? progress;

  /// Center where bursts spawn, in this widget's local pixel
  /// coordinates. Negative anchors are ignored (unresolved probe).
  final Offset anchor;

  /// Approximate width of the highlighted line in the same local
  /// pixel space. Bursts spread across [-burstWidth/2, +burstWidth/2]
  /// around [anchor] to mimic Apple Music's line-wide shimmer.
  final double burstWidth;

  final Color color;
  final bool enabled;

  /// Burst density multiplier (0.25 .. 2).
  final double intensity;

  const WaveLyricParticles({
    super.key,
    required this.clock,
    this.progress,
    this.anchor = Offset.zero,
    this.burstWidth = 0,
    this.color = const Color(0xFFFFB4A2),
    this.enabled = true,
    this.intensity = 1.0,
  });

  @override
  State<WaveLyricParticles> createState() => _WaveLyricParticlesState();
}

class _WaveLyricParticlesState extends State<WaveLyricParticles> {
  static const int _noProgress = -1 << 30;

  final LyricParticleField _field = LyricParticleField();
  int _lastProgress = _noProgress;

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_onClock);
    widget.progress?.addListener(_onProgress);
    _lastProgress = widget.progress?.value ?? _noProgress;
  }

  @override
  void didUpdateWidget(covariant WaveLyricParticles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clock != widget.clock) {
      oldWidget.clock.removeListener(_onClock);
      widget.clock.addListener(_onClock);
    }
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress?.removeListener(_onProgress);
      widget.progress?.addListener(_onProgress);
      _lastProgress = widget.progress?.value ?? _noProgress;
    }
  }

  @override
  void dispose() {
    widget.clock.removeListener(_onClock);
    widget.progress?.removeListener(_onProgress);
    super.dispose();
  }

  double _elapsedSec() {
    final c = widget.clock;
    if (c is Animation<double>) return c.value;
    if (c is ValueListenable<double>) return c.value;
    return 0;
  }

  void _onClock() {
    // Disabled: emit nothing and skip scheduling entirely.
    if (!widget.enabled || !mounted) return;
    _field.step(_elapsedSec());
    _schedulePaint();
  }

  void _onProgress() {
    if (!widget.enabled || !mounted) return;
    final v = widget.progress?.value;
    if (v == null || v == _lastProgress) return;
    final first = _lastProgress == _noProgress;
    _lastProgress = v;
    if (first) return; // initial value is not a highlight change
    // Unresolved anchor (-1,-1): the probe hasn't located the line yet
    // this frame — skip rather than sparkle from the top-left corner.
    if (widget.anchor.dx < 0 || widget.anchor.dy < 0) return;
    _field.emitBurst(
      widget.anchor,
      width: widget.burstWidth,
      count: (26 * widget.intensity).clamp(8, 40).round(),
    );
    _schedulePaint();
  }

  bool _paintScheduled = false;
  void _schedulePaint() {
    if (_paintScheduled) return;
    _paintScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _paintScheduled = false;
      if (mounted) setState(() {}); // repaints the CustomPaint leaf only
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(
            constraints.maxWidth.isFinite ? constraints.maxWidth : 1.0,
            constraints.maxHeight.isFinite ? constraints.maxHeight : 1.0,
          );
          return CustomPaint(
            size: size,
            painter: _LyricParticlePainter(
              field: _field,
              color: widget.color,
              elapsed: _elapsedSec(),
            ),
          );
        },
      ),
    );
  }
}

/// Particle simulation + rendering buffer. Widget-free so it can be
/// unit-tested headlessly.
class LyricParticleField {
  /// Hard cap of live particles — the whole performance budget.
  static const int maxCount = 90;

  final List<_Particle> _particles = <_Particle>[];
  double _lastStepSec = -1;

  /// Number of live particles (for tests / debug overlays).
  int get count => _particles.length;

  /// Live read-only view used by the painter during a frame.
  List<_Particle> get particles => _particles;

  /// Advances the simulation to absolute time [elapsedSec] (seconds).
  /// Steps larger than 0.2s (paused window, minimized app) are clamped
  /// so returning never dumps a stale frame full of dead particles.
  void step(double elapsedSec) {
    if (_lastStepSec < 0) {
      _lastStepSec = elapsedSec;
      return;
    }
    var dt = elapsedSec - _lastStepSec;
    if (dt <= 0) return; // monotonic clocks only; ignore rewinds
    if (dt > 0.2) dt = 0.2;
    _lastStepSec = elapsedSec;

    for (var i = _particles.length - 1; i >= 0; i--) {
      final p = _particles[i];
      p.life += dt;
      if (p.life >= p.maxLife) {
        // Swap-remove: order is irrelevant for point sprites.
        _particles[i] = _particles[_particles.length - 1];
        _particles.removeLast();
        continue;
      }
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      // Slight buoyancy + horizontal sway give the "embers rising" feel.
      p.vy -= 14 * dt;
      p.x += math.sin((p.life + p.seed) * 2.4) * 6 * dt;
    }
  }

  /// Emits an Apple-Music-style sparkle burst along the highlighted
  /// line at [origin]: particles fan out across ±[width]/2 horizontally
  /// (so the whole line shimmers, not one point) and drift upward like
  /// embers. [width] <= 0 falls back to a tight radial fan.
  void emitBurst(Offset origin, {int count = 26, double width = 0}) {
    final n = count.clamp(4, 40);
    final t0 = _lastStepSec < 0 ? 0 : _lastStepSec;
    for (var i = 0; i < n; i++) {
      // Seed each spawn differently so the burst fans out, not clones.
      final jitter = width > 0
          ? (i / (n - 1) - 0.5) * width + (_rand(t0 + i * 1.31) - 0.5) * 18
          : 0.0;
      _spawn(
        Offset(origin.dx + jitter,
            origin.dy + (_rand(i * 0.77 + t0) - 0.5) * 10),
        t0 + i * 0.31,
        ambient: false,
      );
    }
  }

  void _seedAmbient(double t) {
    for (var i = 0; i < 18; i++) {
      _spawn(_ambientOrigin(t + i * 0.53), t, ambient: true);
    }
  }

  Offset _ambientOrigin(double t) {
    // Unused in the event-driven Apple-style mode; kept so headless
    // tests can still exercise ambient spawning deterministically.
    final a = t * 0.6;
    return Offset(
      140 + 110 * math.sin(a),
      260 + 80 * math.cos(a * 0.8),
    );
  }

  void _spawn(Offset origin, double t, {required bool ambient}) {
    if (_particles.length >= maxCount) {
      // Recycle the particle closest to death instead of dropping the
      // newest one, so bursts always land.
      var oldest = 0;
      var best = double.infinity;
      for (var i = 0; i < _particles.length; i++) {
        final remaining = _particles[i].maxLife - _particles[i].life;
        if (remaining < best) {
          best = remaining;
          oldest = i;
        }
      }
      _particles.removeAt(oldest);
    }
    final rnd = _rand(t + _particles.length * 0.37);
    final angle =
        ambient ? -math.pi / 2 + (rnd - 0.5) * 1.6 : rnd * math.pi * 2;
    final speed = ambient ? 8 + rnd * 14 : 26 + _rand(angle + t) * 46;
    _particles.add(
      _Particle(
        x: origin.dx,
        y: origin.dy,
        vx: math.cos(angle) * speed,
        vy: math.sin(angle) * speed * (ambient ? 0.7 : 1),
        size: ambient ? 1.6 + rnd * 2.2 : 2.4 + _rand(speed) * 3.4,
        maxLife: ambient ? 2.6 + rnd * 1.8 : 1.1 + _rand(angle) * 1.2,
        seed: rnd * 10,
      ),
    );
  }

  /// Deterministic cheap pseudo-random from a float seed (avoids
  /// allocating a Random instance per spawn).
  static double _rand(double s) {
    final x = math.sin(s * 127.1 + 311.7) * 43758.5453;
    return x - x.floor();
  }
}

class _Particle {
  double x, y, vx, vy, size, maxLife, life, seed;
  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.maxLife,
    this.life = 0,
    this.seed = 0,
  });

  double get _t => (life / maxLife).clamp(0.0, 1.0);

  /// Quick fade-in, slow fade-out.
  double get alpha => _t < 0.15 ? _t / 0.15 : 1 - (_t - 0.15) / 0.85;

  double get drawSize => size * (1 - _t * 0.45);
}

class _LyricParticlePainter extends CustomPainter {
  final LyricParticleField field;
  final Color color;
  final double elapsed;

  _LyricParticlePainter({
    required this.field,
    required this.color,
    required this.elapsed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final particles = field.particles;
    if (particles.isEmpty) return;
    final core = color;
    final edge = color.withValues(alpha: 0.0);
    final scratch = Paint()..style = PaintingStyle.fill;
    for (final p in particles) {
      final fade = p.alpha.clamp(0.0, 1.0);
      if (fade <= 0.01) continue;
      // Soft glowing mote drawn as three concentric circles sharing one
      // Paint (bright core -> mid halo -> transparent edge). This is
      // intentionally shader-free: constructing a per-particle radial
      // gradient shader churned the SkSL runtime effect cache and
      // crashed kernel_snapshot on Linux/Windows/macOS release builds.
      // No saveLayer needed — plain src-over stacking of alpha-ramped
      // circles gives the same soft look at a fraction of the cost.
      final r = p.drawSize;
      final c = Offset(p.x, p.y);
      scratch.color = core.withValues(alpha: 0.28 * fade);
      canvas.drawCircle(c, r, scratch);
      scratch.color = core.withValues(alpha: 0.45 * fade);
      canvas.drawCircle(c, r * 0.6, scratch);
      scratch.color = Color.alphaBlend(
        core.withValues(alpha: 0.9 * fade),
        edge,
      );
      canvas.drawCircle(c, r * 0.28, scratch);
    }
  }

  @override
  bool shouldRepaint(_LyricParticlePainter old) =>
      old.elapsed != elapsed ||
      old.color != color ||
      !identical(old.field, field);
}
