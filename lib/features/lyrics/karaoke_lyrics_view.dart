import 'dart:math' as math;
import 'dart:ui';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/audio/stream_models.dart';
import '../../core/error/fatal_crumbs.dart';
import '../../core/storage/prefs.dart';
import '../../ui/components/buttons.dart' show LWTooltip;
import '../../ui/components/menus.dart' show fastFlyoutTransition;
import '../../ui/components/states.dart';
import '../../ui/lyrics/lyric_particles.dart';
import '../../ui/lyrics/lyrics_panel.dart';
import '../../ui/theme/haze.dart';
import '../../ui/theme/tokens.dart';
import '../../ui/theme/wave_icons.dart';
import '../player/playback_service.dart';
import 'flutter_lyric_adapter.dart';
import 'lyrics_models.dart';
import 'lyrics_providers.dart';

/// Shared, monotonic seconds clock for the lyric particle effect.
/// One [Ticker] drives every active [WaveLyricParticles] instance
/// (side panel + Now Playing can coexist), so cost stays O(1) no
/// matter how many panes are mounted. The ticker only runs while at
/// least one pane has particles enabled — zero frames when off.
class LyricParticleClock {
  LyricParticleClock._();

  static final LyricParticleClock instance = LyricParticleClock._();

  final ValueNotifier<double> seconds = ValueNotifier<double>(0);
  Ticker? _ticker;
  TickerProvider? _provider;
  int _consumers = 0;
  // Consumers that have particles switched ON. The ticker only runs
  // while at least one is active — the effect costs zero frames when
  // every pane has it disabled.
  int _enabledConsumers = 0;
  DateTime _lastWall = DateTime.now();

  void acquire(TickerProvider provider, {required bool enabled}) {
    _consumers++;
    if (enabled) _enabledConsumers++;
    _arm(provider);
  }

  void updateRegistration({required bool enabled}) {
    _enabledConsumers += enabled ? 1 : -1;
    if (_enabledConsumers < 0) _enabledConsumers = 0;
    if (_enabledConsumers > 0) {
      if (_provider != null) _arm(_provider!);
    } else {
      _ticker?.stop();
    }
  }

  void release() {
    _consumers--;
    _enabledConsumers--;
    if (_enabledConsumers < 0) _enabledConsumers = 0;
    if (_consumers <= 0) {
      _consumers = 0;
      _enabledConsumers = 0;
      _ticker?.stop();
    } else if (_enabledConsumers > 0 && (_ticker == null || !_ticker!.isActive)) {
      // Keep the clock alive rather than silently freezing particles.
      if (_provider != null) _arm(_provider!);
    }
  }

  void _arm(TickerProvider provider) {
    if (_enabledConsumers <= 0) return;
    if (_ticker != null && _ticker!.isActive && identical(_provider, provider)) {
      return;
    }
    _provider = provider;
    _ticker?.dispose();
    _lastWall = DateTime.now();
    _ticker = provider.createTicker(_onTick)..start();
  }

  void _onTick(Duration _) {
    final wall = DateTime.now();
    var dt = wall.difference(_lastWall).inMicroseconds / 1e6;
    _lastWall = wall;
    // Clamp long stalls (minimized window) so the field never sees a
    // giant step; the field clamps too, this keeps the clock sane.
    if (dt < 0) dt = 0;
    if (dt > 0.25) dt = 0.25;
    seconds.value += dt;
  }
}

/// Widget-scoped registration with the shared particle clock: mounts a
/// [WaveLyricParticles] without forcing its owner to own a Ticker or
/// rebuild per frame. The clock only ticks while [enabled] is true.
class _ParticleClockScope extends StatefulWidget {
  final Widget child;
  final bool enabled;
  const _ParticleClockScope({required this.child, required this.enabled});

  @override
  State<_ParticleClockScope> createState() => _ParticleClockScopeState();
}

class _ParticleClockScopeState extends State<_ParticleClockScope>
    with SingleTickerProviderStateMixin {
  late bool _registeredEnabled;

  @override
  void initState() {
    super.initState();
    _registeredEnabled = widget.enabled;
    LyricParticleClock.instance.acquire(this, enabled: _registeredEnabled);
  }

  @override
  void didUpdateWidget(covariant _ParticleClockScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      LyricParticleClock.instance.updateRegistration(enabled: widget.enabled);
    }
  }

  @override
  void dispose() {
    LyricParticleClock.instance.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Post-frame anchor probe for the particle emitter. While particles are
/// enabled it refreshes [onAnchor] with the current active lyric line's
/// position, in the lyrics Stack's local coordinates:
/// - Apple line-sync mode: via a [GlobalKey] on the active row (cheap —
///   only runs when the highlight actually changes).
/// - Word-by-word mode: by locating flutter_lyric's internal ListView
///   element once and indexing its currently visible children.
/// When disabled it renders nothing and does zero work — the effect
/// costs literally nothing until turned on in Settings.
class _ParticleAnchorProbe extends StatefulWidget {
  final bool enabled;
  final LyricsResult result;
  final ValueNotifier<int> positionListenable;
  final ValueNotifier<int> activeLine;
  /// Global key attached to the active row in Apple line-sync mode.
  final GlobalKey activeRowKey;
  /// The lyrics area subtree to search for flutter_lyric's list view.
  final GlobalKey stackKey;
  final bool wordByWord;
  final void Function(Offset anchor) onAnchor;

  const _ParticleAnchorProbe({
    required this.enabled,
    required this.result,
    required this.positionListenable,
    required this.activeLine,
    required this.activeRowKey,
    required this.stackKey,
    required this.wordByWord,
    required this.onAnchor,
  });

  @override
  State<_ParticleAnchorProbe> createState() => _ParticleAnchorProbeState();
}

class _ParticleAnchorProbeState extends State<_ParticleAnchorProbe> {
  int _lastSampled = -2;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      widget.activeLine.addListener(_sample);
      WidgetsBinding.instance.addPostFrameCallback((_) => _sample());
    }
  }

  @override
  void didUpdateWidget(covariant _ParticleAnchorProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        widget.activeLine.addListener(_sample);
        WidgetsBinding.instance.addPostFrameCallback((_) => _sample());
      } else {
        widget.activeLine.removeListener(_sample);
      }
    } else if (widget.enabled && oldWidget.wordByWord != widget.wordByWord) {
      _sample();
    }
  }

  @override
  void dispose() {
    widget.activeLine.removeListener(_sample);
    super.dispose();
  }

  void _sample() {
    if (!mounted || !widget.enabled) return;
    final idx = widget.activeLine.value;
    // In word-by-word mode the wipe moves inside a line; resample even
    // when the index is unchanged, but only from frame callbacks.
    if (!widget.wordByWord && idx == _lastSampled) return;
    _lastSampled = idx;
    widget.onAnchor(widget.wordByWord ? _wordByWordAnchor() : _rowAnchor(idx));
  }

  Offset _rowAnchor(int idx) {
    if (idx < 0) return const Offset(-1, -1);
    final rowCtx = widget.activeRowKey.currentContext;
    return _anchorInStack(rowCtx);
  }

  Offset _wordByWordAnchor() {
    // flutter_lyric renders a ListView whose first visible child is the
    // active line (it auto-scrolls the current line to `defaultAlignment`
    // near the top). Find that ListView element without importing the
    // package's private widgets: any Scrollable under the stack works.
    final stackCtx = widget.stackKey.currentContext;
    if (stackCtx == null) return const Offset(-1, -1);
    Offset? found;
    void visit(Element e) {
      if (found != null) return;
      final ro = e.renderObject;
      // flutter_lyric renders a scrollable list; the first Scrollable under
      // the karaoke stack is that list. Its own paint bounds in global
      // coordinates approximate the active-line area (the lyric widget
      // centers the current line within its viewport).
      if (ro is RenderBox &&
          (e.widget is Scrollable ||
              e.widget.runtimeType.toString().contains('Scrollable'))) {
        if (ro.hasSize) {
          final origin = ro.localToGlobal(Offset.zero);
          found = Offset(origin.dx + ro.size.width * 0.5,
              origin.dy + ro.size.height * 0.42);
        }
        return;
      }
      e.visitChildren(visit);
    }

    try {
      (stackCtx as Element).visitChildren(visit);
    } catch (_) {}
    if (found == null) return const Offset(-1, -1);
    return _toStackLocal(found!);
  }

  Offset _anchorInStack(BuildContext? ctx) {
    if (ctx == null) return const Offset(-1, -1);
    try {
      final box = ctx.findRenderObject();
      final stackBox = widget.stackKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize || stackBox is! RenderBox) {
        return const Offset(-1, -1);
      }
      final topLeft = box.localToGlobal(Offset.zero, ancestor: stackBox);
      return Offset(topLeft.dx + box.size.width * 0.5,
          topLeft.dy + box.size.height * 0.5);
    } catch (_) {
      return const Offset(-1, -1);
    }
  }

  Offset _toStackLocal(Offset globalCenter) {
    final stackBox = widget.stackKey.currentContext?.findRenderObject();
    if (stackBox is! RenderBox) return const Offset(-1, -1);
    try {
      final local = globalCenter - stackBox.localToGlobal(Offset.zero);
      return Offset(local.dx, local.dy);
    } catch (_) {
      return const Offset(-1, -1);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    // Resample the karaoke anchor whenever a new frame lands while the
    // highlight is mid-line (post-frame loop stops when disabled).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled && widget.wordByWord) _sample();
    });
    return const SizedBox.shrink();
  }
}

/// Provider for track-specific lyrics timing offset in milliseconds.
final lyricsOffsetProvider = StateNotifierProvider.family<LyricsOffsetNotifier, int, String>(
  (ref, trackKey) {
    final prefs = ref.watch(prefsProvider);
    return LyricsOffsetNotifier(prefs, trackKey);
  },
);

class LyricsOffsetNotifier extends StateNotifier<int> {
  final Prefs _prefs;
  final String _trackKey;

  LyricsOffsetNotifier(this._prefs, this._trackKey)
      : super(_prefs.getLyricsOffset(_trackKey));

  void adjust(int deltaMs) {
    final next = state + deltaMs;
    state = next;
    _prefs.setLyricsOffset(_trackKey, next);
  }

  void reset() {
    state = 0;
    _prefs.resetLyricsOffset(_trackKey);
  }

  void setOffset(int offsetMs) {
    state = offsetMs;
    _prefs.setLyricsOffset(_trackKey, offsetMs);
  }
}

/// Provider for transliteration display toggle.
final lyricsTransliterationProvider =
    StateNotifierProvider<LyricsTransliterationNotifier, bool>((ref) {
  final prefs = ref.watch(prefsProvider);
  return LyricsTransliterationNotifier(prefs);
});

class LyricsTransliterationNotifier extends StateNotifier<bool> {
  final Prefs _prefs;

  LyricsTransliterationNotifier(this._prefs)
      : super(_prefs.lyricsTransliteration);

  void toggle() {
    state = !state;
    _prefs.setLyricsTransliteration(state);
  }
}

/// Provider for the "Particle effect in lyrics" toggle (persisted).
/// When enabled, shimmering motes drift off the highlighted lyric line.
final lyricParticlesProvider =
    StateNotifierProvider<LyricParticlesNotifier, bool>((ref) {
  final prefs = ref.watch(prefsProvider);
  return LyricParticlesNotifier(prefs);
});

class LyricParticlesNotifier extends StateNotifier<bool> {
  final Prefs _prefs;

  LyricParticlesNotifier(this._prefs) : super(_prefs.lyricParticles);

  void toggle() {
    state = !state;
    _prefs.setLyricParticles(state);
  }

  void setEnabled(bool enabled) {
    if (state == enabled) return;
    state = enabled;
    _prefs.setLyricParticles(enabled);
  }
}

/// Format offset in ms to display string (e.g. "+0.5s", "-1.0s", "0.0s").
String formatOffsetDisplay(int offsetMs) {
  if (offsetMs == 0) return '0.0s';
  final sign = offsetMs > 0 ? '+' : '-';
  final secs = (offsetMs.abs() / 1000.0).toStringAsFixed(1);
  return '$sign${secs}s';
}

/// Apple Music Karaoke-Style Lyrics Engine.
///
/// Features:
/// - Progressive syllable color wipe for word-synced lyrics.
/// - Inactive lines rendered with reduced opacity and soft blur (`ImageFilter.blur`).
/// - Active line pops with 1.025x scale and prominent Segoe UI typography.
/// - Timing offset controls: `[-] 0.0s [+] [Reset]` (persisted per track).
/// - Transliteration / Romaji toggle.
/// - Smooth auto-scrolling with manual scroll detection and "Return to current" pill.
/// - Interactive tap-to-seek on any lyric line.
class WaveKaraokeLyricsView extends ConsumerStatefulWidget {
  final PlayableTrack track;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;
  final double? fontSize;
  final bool fillRemainingSpace;

  const WaveKaraokeLyricsView({
    super.key,
    required this.track,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
    this.fontSize,
    this.fillRemainingSpace = true,
  });

  @override
  ConsumerState<WaveKaraokeLyricsView> createState() =>
      _WaveKaraokeLyricsViewState();
}

class _WaveKaraokeLyricsViewState extends ConsumerState<WaveKaraokeLyricsView>
    with SingleTickerProviderStateMixin {
  late final LyricController _lyricController;
  bool _following = true;
  late final Ticker _ticker;
  final ValueNotifier<int> _interpolatedPositionMs = ValueNotifier<int>(0);
  // Clock subscriptions owned here (initState/dispose), not watched in
  // build: position/isPlaying/speed tick 10Hz and feed only ticker/drift
  // side effects, never widget output.
  ProviderSubscription<Duration>? _posSub;
  ProviderSubscription<bool>? _playingSub;
  ProviderSubscription<double>? _speedSub;
  int _lastAudioMs = 0;
  DateTime _lastSyncTime = DateTime.now();
  bool _isPlaying = false;
  double _speed = 1.0;
  int _offsetMs = 0;
  String? _currentTrackKey;
  LyricsResult? _currentResult;
  bool _lastTransliteration = true;
  bool _lastWordByWord = true;
  // Fullscreen (theater) mode for the lyrics + poster screen.
  bool _fullscreen = false;
  // Active lyric line index — drives particle bursts on highlight change.
  final ValueNotifier<int> _activeLine = ValueNotifier<int>(-1);
  // Anchor of the highlighted line in the lyrics Stack's local coords,
  // refreshed by a lightweight post-frame probe (no extra listeners).
  Offset _particleAnchor = const Offset(-1, -1);
  // Keys used by the anchor probe to locate the highlighted line.
  final GlobalKey _lyricStackKey = GlobalKey();
  final GlobalKey _appleActiveRowKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _lyricController = LyricController();
    // Mirror flutter_lyric's active-line notifier into [_activeLine] so
    // particle bursts fire on line transitions in word-by-word mode.
    // (Public field of LyricController in flutter_lyric 3.x — note the
    // package's own spelling "activeIndexNotifiter".)
    _lyricController.activeIndexNotifiter.addListener(_onLyricActiveChanged);
    _lyricController.setOnTapLineCallback((duration) {
      final seekTargetMs = duration.inMilliseconds + _offsetMs;
      ref.read(playbackServiceProvider.notifier).seek(
            Duration(milliseconds: math.max(0, seekTargetMs)),
          );
      _lyricController.stopSelection();
      if (!_following) {
        setState(() => _following = true);
      }
    });

    _lyricController.isSelectingNotifier.addListener(_onSelectingChanged);
    _ticker = createTicker(_onTick);
    // Subscribe without rebuilding: each emission only re-syncs the
    // interpolation clock (same math the in-build block used to run).
    _posSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.position),
      (_, _) => _syncPlaybackClock(),
    );
    _playingSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.isPlaying),
      (_, _) => _syncPlaybackClock(),
    );
    _speedSub = ref.listenManual(
      playbackServiceProvider.select((s) => s.speed),
      (_, _) => _syncPlaybackClock(),
    );
    _syncPlaybackClock();
  }

  void _onSelectingChanged() {
    final selecting = _lyricController.isSelectingNotifier.value;
    if (selecting && _following) {
      setState(() => _following = false);
    } else if (!selecting && !_following) {
      setState(() => _following = true);
    }
  }

  /// Mirrors flutter_lyric's active line into [_activeLine] (word-by-word
  /// mode). Only notifies on change, so particle bursts stay event-driven.
  void _onLyricActiveChanged() {
    try {
      final idx = _lyricController.activeIndexNotifiter.value;
      if (_activeLine.value != idx) _activeLine.value = idx;
    } catch (_) {}
  }

  /// Best-effort native fullscreen for theater mode. window_manager is
  /// initialized on every desktop target; failures are swallowed so a
  /// missing WM backend can never break the lyrics pane.
  Future<void> _setNativeFullscreen(bool on) async {
    try {
      await windowManager.setFullScreen(on);
    } catch (_) {}
  }

  void _toggleFullscreen() {
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    _setNativeFullscreen(next);
  }

  @override
  void dispose() {
    _posSub?.close();
    _playingSub?.close();
    _speedSub?.close();
    _ticker.dispose();
    _interpolatedPositionMs.dispose();
    _activeLine.dispose();
    try {
      _lyricController.activeIndexNotifiter.removeListener(_onLyricActiveChanged);
    } catch (_) {}
    // Leaving karaoke while in theater mode must never strand the
    // window fullscreen with no way back from this pane.
    if (_fullscreen) _setNativeFullscreen(false);
    _lyricController.isSelectingNotifier.removeListener(_onSelectingChanged);
    _lyricController.dispose();
    super.dispose();
  }

  DateTime _lastTickWall = DateTime.now();

  void _onTick(Duration _) {
    // Guarded: a throw here (e.g. a progress value the lyric
    // controller rejects) aborts the whole process via fail-fast.
    runGuarded('karaoke.tick', () {
      if (!_isPlaying) return;
    // Cap interpolation at ~30Hz: the ticker fires at display refresh
    // (up to 144Hz), and every admitted tick pushes setProgress + a
    // lyric-view update. Syllable transitions are 50-200ms, so 30Hz
    // loses nothing visible while halving per-frame Dart + raster
    // work — the margin that keeps karaoke smooth while motion art
    // eats the rest of the budget. Accuracy is unaffected — elapsed
    // is wall-clock based, not tick-counted.
    final wall = DateTime.now();
    if (wall.difference(_lastTickWall).inMicroseconds < 33000) return;
    _lastTickWall = wall;
    final elapsed = wall.difference(_lastSyncTime).inMilliseconds;
    final currentMs =
        _lastAudioMs + (elapsed * _speed).round() - _offsetMs;
    _interpolatedPositionMs.value = currentMs;
    _lyricController.setProgress(Duration(milliseconds: math.max(0, currentMs)));
    });
  }

  /// Syncs the 30Hz interpolation clock from the 10Hz playback snapshot.
  /// Runs from tick listeners and rare rebuilds — writes only the ticker,
  /// the position notifier, and the lyric controller, never setState, so
  /// it never schedules extra frames. Same math the in-build block ran,
  /// only the trigger changed.
  void _syncPlaybackClock() {
    final snap = ref.read(playbackServiceProvider);
    final audioMs = snap.position.inMilliseconds;
    _isPlaying = snap.isPlaying;
    _speed = snap.speed <= 0 ? 1.0 : snap.speed;
    if (!_isPlaying) {
      _lastAudioMs = audioMs;
      _lastSyncTime = DateTime.now();
      final effectiveMs = audioMs - _offsetMs;
      _interpolatedPositionMs.value = effectiveMs;
      _lyricController.setProgress(Duration(milliseconds: math.max(0, effectiveMs)));
    } else if (audioMs != _lastAudioMs) {
      final elapsed = DateTime.now().difference(_lastSyncTime).inMilliseconds;
      final predicted = _lastAudioMs + (elapsed * _speed).round();
      final drift = audioMs - predicted;
      if (drift <= -450 || drift >= 250) {
        _lastAudioMs = audioMs;
        _lastSyncTime = DateTime.now();
        final effectiveMs = audioMs - _offsetMs;
        _interpolatedPositionMs.value = effectiveMs;
        _lyricController.setProgress(
            Duration(milliseconds: math.max(0, effectiveMs)));
      }
    }

    if (_isPlaying && !_ticker.isActive) {
      _ticker.start();
    } else if (!_isPlaying && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: position/isPlaying/speed are subscribed in initState
    // (_syncPlaybackClock), not watched here. They tick 10Hz and feed
    // only ticker/drift side effects, never widget output — watching them
    // rebuilt the whole toolbar + style + list 10x/sec for nothing.
    final offsetMs = ref.watch(lyricsOffsetProvider(widget.track.queueKey));
    final showTransliteration = ref.watch(lyricsTransliterationProvider);
    // Select the single pref: toggling theme/quality elsewhere must
    // not rebuild the karaoke view (it recreates the lyric adapter).
    final wordByWord =
        ref.watch(prefsProvider.select((p) => p.wordByWord));
    // Particle toggle lives in its own provider so flipping theme or
    // quality elsewhere never rebuilds this pane; watching it here is
    // what makes Settings → "Particle effect in lyrics" apply live.
    final particlesOn = ref.watch(lyricParticlesProvider);
    final async = ref.watch(waveLyricsProvider(widget.track.queueKey));

    _offsetMs = offsetMs;
    // Covers offset/track/data-driven syncs; clock ticks arrive via the
    // initState subscriptions. Rare either way (no per-tick rebuilds).
    _syncPlaybackClock();

    return async.when(
      loading: () => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: const WaveLoading(label: 'Finding lyrics…'),
      ),
      error: (e, _) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: WaveError(
          title: 'Lyrics unavailable',
          message: 'Check your connection and try again.',
          onRetry: () =>
              ref.invalidate(waveLyricsProvider(widget.track.queueKey)),
        ),
      ),
      data: (result) {
        if (result.isInstrumental) {
          return const WaveEmpty(
            icon: FluentIcons.music_note,
            title: 'Instrumental',
            subtitle: 'No lyrics for this track.',
          );
        }
        if (result.isEmpty) {
          return WaveEmpty(
            icon: FluentIcons.microphone,
            title: 'No lyrics found',
            subtitle: 'Try another track or check back later.',
            actionLabel: 'Try again',
            onAction: () =>
                ref.invalidate(waveLyricsProvider(widget.track.queueKey)),
          );
        }
        if (!result.isSynced && result.lines.length < 2) {
          return _KaraokePlainLyrics(
            text: result.plainLyrics,
            compact: widget.compact,
            showHeaderControls: widget.showHeaderControls,
            onClose: widget.onClose,
          );
        }

        final isRtl = result.lines.any((l) => l.isRtl);

        if (_currentTrackKey != widget.track.queueKey ||
            _currentResult != result ||
            _lastTransliteration != showTransliteration ||
            _lastWordByWord != wordByWord) {
          _currentTrackKey = widget.track.queueKey;
          _currentResult = result;
          _lastTransliteration = showTransliteration;
          _lastWordByWord = wordByWord;
          if (wordByWord) {
            final model = convertToFlutterLyricModel(
              result,
              showTransliteration: showTransliteration,
              wordByWord: true,
            );
            _lyricController.loadLyricModel(model);
            final effectiveMs = _interpolatedPositionMs.value;
            _lyricController.setProgress(
                Duration(milliseconds: math.max(0, effectiveMs)));
          }
        }

        final style = buildAppleMusicLyricStyle(
          context,
          compact: widget.compact,
          fontSize: widget.fontSize,
          isDark: waveIsDark(context),
          isRtl: isRtl,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeaderControls)
              _KaraokeToolbar(
                track: widget.track,
                result: result,
                offsetMs: offsetMs,
                showTransliteration: showTransliteration,
                following: _following,
                compact: widget.compact,
                wordByWord: wordByWord,
                fullscreen: _fullscreen,
                onClose: widget.onClose,
                onToggleFullscreen: _toggleFullscreen,
                onToggleFollowing: () {
                  if (!_following) {
                    _lyricController.stopSelection();
                    setState(() => _following = true);
                  } else {
                    setState(() => _following = false);
                  }
                },
              ),
            Expanded(
              child: wordByWord && result.isSynced
                  ? Stack(
                      key: _lyricStackKey,
                      children: [
                        Positioned.fill(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: LyricView(
                              controller: _lyricController,
                              style: style,
                            ),
                          ),
                        ),
                        // Resolves the highlighted line's position (in this
                        // Stack's local coords) and feeds _particleAnchor.
                        _ParticleAnchorProbe(
                          enabled: particlesOn,
                          result: result,
                          positionListenable: _interpolatedPositionMs,
                          activeLine: _activeLine,
                          activeRowKey: _appleActiveRowKey,
                          stackKey: _lyricStackKey,
                          wordByWord: true,
                          onAnchor: (a) => _particleAnchor = a,
                        ),
                        // Particle motes ride above the lyric view for
                        // BOTH modes (karaoke wipe and Apple line-sync),
                        // anchored to the highlighted line. The clock
                        // ticker only runs while particles are enabled —
                        // zero frames when off. IgnorePointer keeps tap-
                        // to-seek and scrolling exactly as before.
                        Positioned.fill(
                          child: IgnorePointer(
                            child: _ParticleClockScope(
                              enabled: particlesOn,
                              child: WaveLyricParticles(
                                clock: LyricParticleClock.instance.seconds,
                                progress: _activeLine,
                                anchor: _particleAnchor,
                                color: waveAccent(context),
                                enabled: particlesOn,
                              ),
                            ),
                          ),
                        ),
                        if (!_following)
                          Positioned(
                            right: 16,
                            bottom: 16,
                            child: _ReturnToCurrentPill(
                              onTap: () {
                                _lyricController.stopSelection();
                                setState(() => _following = true);
                              },
                            ),
                          ),
                      ],
                    )
                  : _AppleLineLyricsView(
                      stackKey: _lyricStackKey,
                      activeRowKey: _appleActiveRowKey,
                      particleClockScopeBuilder: (child) =>
                          _ParticleClockScope(
                        enabled: particlesOn,
                        child: child,
                      ),
                      onActiveIndexChanged: (i) {
                        if (_activeLine.value != i) _activeLine.value = i;
                      },
                      anchorProbeBuilder: () => _ParticleAnchorProbe(
                        enabled: particlesOn,
                        result: result,
                        positionListenable: _interpolatedPositionMs,
                        activeLine: _activeLine,
                        activeRowKey: _appleActiveRowKey,
                        stackKey: _lyricStackKey,
                        wordByWord: false,
                        onAnchor: (a) => _particleAnchor = a,
                      ),
                      result: result,
                      positionListenable: _interpolatedPositionMs,
                      activeLineListenable: _activeLine,
                      particlesEnabled: particlesOn,
                      particleAnchor: _particleAnchor,
                      particleColor: waveAccent(context),
                      compact: widget.compact,
                      fontSize: widget.fontSize,
                      showTransliteration: showTransliteration,
                      following: _following,
                      onUserScroll: () {
                        if (_following) setState(() => _following = false);
                      },
                      onResume: () {
                        _lyricController.stopSelection();
                        setState(() => _following = true);
                      },
                      onSeekLineMs: (lineMs) {
                        final seekTargetMs = lineMs + _offsetMs;
                        ref.read(playbackServiceProvider.notifier).seek(
                              Duration(
                                  milliseconds: math.max(0, seekTargetMs)),
                            );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class KaraokeWordGroup {
  final List<LyricSyllable> syllables;
  final bool hasTrailingSpace;

  const KaraokeWordGroup({
    required this.syllables,
    this.hasTrailingSpace = true,
  });
}

List<KaraokeWordGroup> groupSyllablesIntoWords(
  List<LyricSyllable> syllables,
  String lineText,
) {
  final words = <KaraokeWordGroup>[];
  var currentWordSyllables = <LyricSyllable>[];

  for (var i = 0; i < syllables.length; i++) {
    final syl = syllables[i];
    currentWordSyllables.add(syl);

    var isWordEnd = false;
    if (syl.text.endsWith(' ')) {
      isWordEnd = true;
    } else if (i == syllables.length - 1) {
      isWordEnd = true;
    } else {
      final nextSyl = syllables[i + 1];
      if (nextSyl.text.startsWith(' ')) {
        isWordEnd = true;
      } else {
        final combined = '${syl.text}${nextSyl.text}';
        if (!lineText.contains(combined)) {
          isWordEnd = true;
        }
      }
    }

    if (isWordEnd) {
      words.add(KaraokeWordGroup(
        syllables: currentWordSyllables,
        hasTrailingSpace: i < syllables.length - 1,
      ));
      currentWordSyllables = [];
    }
  }

  if (currentWordSyllables.isNotEmpty) {
    words.add(KaraokeWordGroup(
      syllables: currentWordSyllables,
      hasTrailingSpace: false,
    ));
  }
  return words;
}

double calculateSyllableProgress(LyricSyllable syl, int posMs) {
  final startMs = syl.timeMs;
  final durMs = math.max(1, syl.durationMs);
  final endMs = startMs + durMs;
  if (posMs <= startMs) return 0.0;
  if (posMs >= endMs) return 1.0;
  return (posMs - startMs) / durMs;
}

/// Single Lyric Line rendering with Apple Music Karaoke progressive wipe,
/// blur falloff, and Segoe UI typography.
class WaveKaraokeLyricLine extends StatefulWidget {
  final LyricLine line;
  final int positionMs;
  final ValueListenable<int>? positionListenable;
  final bool isActive;
  final bool isPast;
  final bool compact;
  final bool showTransliteration;
  final double? fontSize;
  final bool karaoke;
  final bool softenIdle;

  /// Reports the highlighted line's rect (in the enclosing lyrics Stack's
  /// local coordinates) so the particle effect can anchor bursts on it.
  final void Function(Rect lineRect)? onActiveRect;

  const WaveKaraokeLyricLine({
    super.key,
    required this.line,
    required this.positionMs,
    this.positionListenable,
    required this.isActive,
    required this.isPast,
    this.compact = false,
    this.showTransliteration = true,
    this.fontSize,
    this.karaoke = true,
    this.softenIdle = true,
    this.onActiveRect,
  });

  @override
  State<WaveKaraokeLyricLine> createState() => _WaveKaraokeLyricLineState();
}

class _WaveKaraokeLyricLineState extends State<WaveKaraokeLyricLine> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    final baseFontSize = widget.fontSize ?? (widget.compact ? 28.0 : 36.0);

    final activeTextColor = dark ? const Color(0xFFF6F4EF) : const Color(0xFF18181B);
    final idleTextColor = (dark ? const Color(0xFFF6F4EF) : const Color(0xFF18181B))
        .withValues(
          alpha: widget.softenIdle ? (widget.isPast ? 0.38 : 0.44) : 0.92,
        );

    final activeStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: activeTextColor,
      height: 1.42,
      letterSpacing: -0.3,
      shadows: widget.isActive
          ? [
              Shadow(
                color: activeTextColor.withValues(alpha: dark ? 0.28 : 0.14),
                blurRadius: 16,
                offset: const Offset(0, 1),
              ),
            ]
          : null,
    );

    // Style for unsung words on the ACTIVE line: identical font metrics to prevent character jitter!
    final activeUnsungStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w700,
      color: activeTextColor.withValues(alpha: 0.38),
      height: 1.42,
      letterSpacing: -0.3,
    );

    final idleStyle = TextStyle(
      fontSize: baseFontSize,
      fontWeight: FontWeight.w600,
      color: _isHovered
          ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.88)
          : idleTextColor,
      height: 1.42,
      letterSpacing: -0.3,
    );

    Widget content;

    final useKaraokeWipe = widget.karaoke && widget.isActive;
    final effectiveSyllables = useKaraokeWipe
        ? (widget.line.hasSyllables
            ? widget.line.syllables
            : interpolateLineSyllables(
                text: widget.line.text,
                startTimeMs: widget.line.timeMs,
                durationMs: widget.line.durationMs,
              ))
        : const <LyricSyllable>[];

    if (effectiveSyllables.isNotEmpty) {
      final words =
          groupSyllablesIntoWords(effectiveSyllables, widget.line.text);

      Widget buildSyllableWrap(int posMs) {
        return Wrap(
          textDirection:
              widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final word in words)
              Row(
                mainAxisSize: MainAxisSize.min,
                textDirection:
                    widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
                children: [
                  for (final syl in word.syllables)
                    _KaraokeSyllableWidget(
                      text: syl.text.trimRight(),
                      progress: calculateSyllableProgress(syl, posMs),
                      activeStyle: activeStyle,
                      idleStyle: activeUnsungStyle,
                      highlightColor: accent,
                      isRtl: widget.line.isRtl,
                    ),
                  if (word.hasTrailingSpace) Text(' ', style: activeUnsungStyle),
                ],
              ),
          ],
        );
      }

      if (widget.positionListenable != null) {
        content = ValueListenableBuilder<int>(
          valueListenable: widget.positionListenable!,
          builder: (context, posMs, _) => buildSyllableWrap(posMs),
        );
      } else {
        content = buildSyllableWrap(widget.positionMs);
      }
    } else {
      // Standard line-timed or idle line
      content = Text(
        widget.line.text,
        style: widget.isActive ? activeStyle : idleStyle,
        textDirection: widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
        softWrap: true,
        overflow: TextOverflow.visible,
      );
    }

    final showBlur =
        widget.softenIdle && !widget.isActive && !_isHovered && !reduceMotion;

    Widget body = AnimatedDefaultTextStyle(
      duration: WaveMotion.fast,
      style: widget.isActive ? activeStyle : idleStyle,
      child: Column(
        crossAxisAlignment:
            widget.line.isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          if (widget.showTransliteration && widget.line.transliteration.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.line.transliteration,
                style: TextStyle(
                  fontSize: baseFontSize * 0.52,
                  fontStyle: FontStyle.italic,
                  color: (dark ? Colors.white : Colors.black).withValues(
                    alpha: widget.isActive ? 0.72 : 0.40,
                  ),
                ),
                textDirection:
                    widget.line.isRtl ? TextDirection.rtl : TextDirection.ltr,
              ),
            ),
        ],
      ),
    );

    if (showBlur) {
      body = ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: widget.karaoke ? 1.15 : 1.8,
          sigmaY: widget.karaoke ? 1.15 : 1.8,
        ),
        child: Opacity(
          opacity: widget.karaoke ? 0.88 : 0.92,
          child: body,
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Builder(
        builder: (context) {
          // Cheap post-frame probe: only the ACTIVE line reports its
          // rect, and only when particles are listening for it. One
          // localToFrame per highlight change — no listeners, no
          // per-frame cost.
          if (widget.isActive && widget.onActiveRect != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final ro = context.findRenderObject();
              final cb = widget.onActiveRect;
              if (ro is RenderBox && ro.hasSize && cb != null) {
                try {
                  cb(ro.localToGlobal(Offset.zero) & ro.size);
                } catch (_) {
                  // Detached mid-frame: skip this report.
                }
              }
            });
          }
          return AnimatedContainer(
            duration: WaveMotion.normal,
            curve: Curves.easeOutCubic,
            transform: Matrix4.diagonal3Values(
              widget.isActive ? 1.025 : 1.0,
              widget.isActive ? 1.025 : 1.0,
              1.0,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 8 : 12,
              vertical: widget.karaoke ? 4 : 8,
            ),
            decoration: BoxDecoration(
              color: _isHovered && !widget.isActive
                  ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: body,
          );
        },
      ),
    );
  }
}

/// Progressive fill / wipe for an individual syllable with soft anti-aliased edge.
class _KaraokeSyllableWidget extends StatelessWidget {
  final String text;
  final double progress;
  final TextStyle activeStyle;
  final TextStyle idleStyle;
  final Color highlightColor;
  final bool isRtl;

  const _KaraokeSyllableWidget({
    required this.text,
    required this.progress,
    required this.activeStyle,
    required this.idleStyle,
    required this.highlightColor,
    this.isRtl = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    if (progress <= 0.0) {
      return Text(text, style: idleStyle);
    }
    if (progress >= 1.0) {
      return Text(text, style: activeStyle);
    }

    final activeColor = activeStyle.color ?? Colors.white;
    final idleColor = idleStyle.color ?? const Color(0x61FFFFFF);

    const feather = 0.035;
    final stop1 = (progress - feather).clamp(0.0, 1.0);
    final stop2 = (progress + feather).clamp(0.0, 1.0);

    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        return LinearGradient(
          begin: isRtl ? Alignment.centerRight : Alignment.centerLeft,
          end: isRtl ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            activeColor,
            activeColor,
            idleColor,
            idleColor,
          ],
          stops: [0.0, stop1, stop2, 1.0],
        ).createShader(bounds);
      },
      child: Text(text, style: activeStyle),
    );
  }
}



/// Top toolbar with timing controls, transliteration toggle, and close button.
/// Lyrics source switcher (Now Playing toolbar): Auto + every provider
/// with the effective pick checked, plus `Try another source` which
/// re-runs the race excluding the current provider.
class _SourceMenu extends ConsumerWidget {
  final PlayableTrack track;
  final LyricsResult result;

  const _SourceMenu({required this.track, required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueKey = track.queueKey;
    final override = ref.watch(lyricsProviderOverrideProvider(queueKey));
    final defaultId =
        ref.watch(prefsProvider.select((p) => p.lyricsProviderId));
    final effective = override ?? defaultId;
    final currentId = lyricsSourceToProviderId(result.source);

    void apply(String? pickedId) {
      if (pickedId == null) {
        ref
            .read(lyricsExcludedProvidersProvider(queueKey).notifier)
            .state = retryLyricsExcludingCurrent(
          currentId: currentId,
          excludes: ref.read(lyricsExcludedProvidersProvider(queueKey)),
        );
      } else {
        final next = nextLyricsSelection(
          pickedId: pickedId,
          currentId: currentId,
          currentExcludes:
              ref.read(lyricsExcludedProvidersProvider(queueKey)),
        );
        ref.read(lyricsProviderOverrideProvider(queueKey).notifier).state =
            next.override;
        ref.read(lyricsExcludedProvidersProvider(queueKey).notifier).state =
            next.excludes;
      }
      ref.invalidate(waveLyricsProvider(queueKey));
    }

    return LWTooltip(
      message: result.source.isNotEmpty
          ? 'Source: ${result.source} · Change'
          : 'Change lyrics source',
      child: DropDownButton(
        placement: FlyoutPlacementMode.bottomRight,
        transitionBuilder: fastFlyoutTransition,
        items: [
          for (final provider in LyricsProviderId.values)
            MenuFlyoutItem(
              leading: effective == provider.id
                  ? const Icon(FluentIcons.check_mark, size: 13)
                  : const SizedBox(width: 13),
              text: Text(provider.title),
              onPressed: () => apply(provider.id),
            ),
          const MenuFlyoutSeparator(),
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.refresh, size: 13),
            text: const Text('Try another source'),
            onPressed: () => apply(null),
          ),
        ],
        buttonBuilder: (context, onOpen) => _MiniIconButton(
          icon: WaveIcons.lyrics,
          onTap: () => onOpen?.call(),
        ),
      ),
    );
  }
}

class _KaraokeToolbar extends ConsumerWidget {
  final PlayableTrack track;
  final LyricsResult result;
  final int offsetMs;
  final bool showTransliteration;
  final bool following;
  final bool compact;
  final bool wordByWord;
  final bool fullscreen;
  final VoidCallback? onClose;
  final VoidCallback onToggleFollowing;
  final VoidCallback? onToggleFullscreen;

  const _KaraokeToolbar({
    required this.track,
    required this.result,
    required this.offsetMs,
    required this.showTransliteration,
    required this.following,
    required this.compact,
    this.wordByWord = true,
    this.fullscreen = false,
    this.onClose,
    required this.onToggleFollowing,
    this.onToggleFullscreen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final offsetNotifier =
        ref.read(lyricsOffsetProvider(track.queueKey).notifier);
    final transliterationNotifier =
        ref.read(lyricsTransliterationProvider.notifier);

    final offsetDisplay = formatOffsetDisplay(offsetMs);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 8 : 4,
        4,
        compact ? 8 : 4,
        8,
      ),
      child: WaveGlass(
        blur: false,
        borderRadius: WaveRadius.floatingRadius,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: 6,
        ),
        child: Row(
        children: [
          Expanded(
            child: Text(
              wordByWord
                  ? (result.isWordSynced
                      ? 'Karaoke · Syllable Synced'
                      : result.isSynced
                          ? 'Synced Lyrics'
                          : result.source.isNotEmpty
                              ? result.source
                              : 'Lyrics')
                  : result.isSynced
                      ? 'Apple Music · Line Synced'
                      : result.source.isNotEmpty
                          ? result.source
                          : 'Lyrics',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WaveType.meta.copyWith(
                fontWeight: FontWeight.w600,
                color: waveTextPrimary(context),
              ),
            ),
          ),
          // Lyrics source switcher: pick a provider (tried first, the
          // current one excluded from fallback) or retry with the best
          // provider excluding the current one.
          _SourceMenu(
            track: track,
            result: result,
          ),
          const SizedBox(width: 8),
          // Timing Offset Controls: [-] offset [+] [Reset]
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(WaveRadius.controls),
              border: Border.all(
                color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.12),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LWTooltip(
                  message: 'Lyrics earlier (-0.5s)',
                  child: _MiniIconButton(
                    icon: FluentIcons.remove,
                    onTap: () => offsetNotifier.adjust(-500),
                  ),
                ),
                LWTooltip(
                  message: 'Timing offset for this track',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      offsetDisplay,
                      style: WaveType.meta.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                        color: offsetMs != 0
                            ? accent
                            : waveTextPrimary(context),
                      ),
                    ),
                  ),
                ),
                LWTooltip(
                  message: 'Lyrics later (+0.5s)',
                  child: _MiniIconButton(
                    icon: FluentIcons.add,
                    onTap: () => offsetNotifier.adjust(500),
                  ),
                ),
                if (offsetMs != 0)
                  LWTooltip(
                    message: 'Reset offset to 0.0s',
                    child: _MiniIconButton(
                      icon: FluentIcons.reset,
                      onTap: offsetNotifier.reset,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Transliteration / Romaji Toggle
          LWTooltip(
            message: showTransliteration
                ? 'Transliteration enabled'
                : 'Enable transliteration',
            child: _MiniIconButton(
              icon: FluentIcons.globe,
              active: showTransliteration,
              onTap: transliterationNotifier.toggle,
            ),
          ),
          const SizedBox(width: 4),
          LWTooltip(
            message: following
                ? 'Pause automatic scrolling'
                : 'Return to the line being sung',
            child: _MiniIconButton(
              icon: following ? FluentIcons.pin : FluentIcons.unpin,
              active: following,
              onTap: onToggleFollowing,
            ),
          ),
          if (onToggleFullscreen != null) ...[
            const SizedBox(width: 4),
            LWTooltip(
              message: fullscreen
                  ? 'Exit fullscreen'
                  : 'Fullscreen lyrics (theater mode)',
              child: _MiniIconButton(
                // NOTE: `FluentIcons.compress` does not exist in the pinned
                // fluent_ui version and broke the Linux/Windows/macOS builds.
                // Use `chrome_minimize`, which is present in all versions.
                icon: fullscreen
                    ? FluentIcons.chrome_minimize
                    : FluentIcons.full_screen,
                active: fullscreen,
                onTap: onToggleFullscreen!,
              ),
            ),
          ],
          if (onClose != null) ...[
            const SizedBox(width: 6),
            LWTooltip(
              message: 'Close panel',
              child: _MiniIconButton(
                icon: WaveIcons.close,
                onTap: onClose!,
              ),
            ),
          ],
        ],
        ),
      ),
    );
  }
}

class _MiniIconButton extends StatefulWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _MiniIconButton({
    required this.icon,
    this.active = false,
    required this.onTap,
  });

  @override
  State<_MiniIconButton> createState() => _MiniIconButtonState();
}

class _MiniIconButtonState extends State<_MiniIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);
    final color = widget.active
        ? accent
        : _hover
            ? (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
            : (dark ? WaveColors.textPrimary : WaveColors.lightTextPrimary)
                .withValues(alpha: 0.88);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: _hover
                ? (dark ? Colors.white : Colors.black).withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Center(
            child: Icon(widget.icon, size: 13, color: color),
          ),
        ),
      ),
    );
  }
}

/// Floating "Return to current" pill when manual scrolling is engaged.
class _ReturnToCurrentPill extends StatelessWidget {
  final VoidCallback onTap;
  const _ReturnToCurrentPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    final accent = waveAccent(context);

    return WaveHaze(
      level: LwHazeLevel.l2,
      base: (dark ? WaveColors.surfaceRaised : WaveColors.lightSurfaceRaised)
          .withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: waveDivider(context)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.down, size: 12, color: accent),
                const SizedBox(width: 6),
                Text(
                  'Return to current',
                  style: WaveType.label.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple Music default lyrics: the whole current line is sharp and
/// fully lit. Past and upcoming lines stay dim with a slight blur.
class _AppleLineLyricsView extends StatefulWidget {
  final LyricsResult result;
  final ValueNotifier<int> positionListenable;
  /// Mirrors the active line index so particle bursts fire on highlight
  /// changes without rebuilding the row list (rows are cached anyway).
  final ValueNotifier<int>? activeLineListenable;
  final bool particlesEnabled;
  final Offset particleAnchor;
  final Color particleColor;
  // Anchor plumbing shared with the parent karaoke state: keys locating
  // the lyrics Stack / active row, plus builders for the parent-owned
  // clock scope and anchor probe (keeps one LyricParticleClock owner).
  final GlobalKey? stackKey;
  final GlobalKey? activeRowKey;
  final Widget Function(Widget child) particleClockScopeBuilder;
  final Widget Function()? anchorProbeBuilder;
  final ValueChanged<int>? onActiveIndexChanged;
  final bool compact;
  final double? fontSize;
  final bool showTransliteration;
  final bool following;
  final VoidCallback onUserScroll;
  final VoidCallback onResume;
  final ValueChanged<int> onSeekLineMs;

  const _AppleLineLyricsView({
    required this.result,
    required this.positionListenable,
    this.activeLineListenable,
    this.particlesEnabled = false,
    this.particleAnchor = Offset.zero,
    this.particleColor = const Color(0xFFFFB4A2),
    this.stackKey = null,
    this.activeRowKey = null,
    this.particleClockScopeBuilder = _defaultPassthrough,
    this.anchorProbeBuilder,
    this.onActiveIndexChanged,
    required this.compact,
    required this.fontSize,
    required this.showTransliteration,
    required this.following,
    required this.onUserScroll,
    required this.onResume,
    required this.onSeekLineMs,
  });

  static Widget _defaultPassthrough(Widget child) => child;

  @override
  State<_AppleLineLyricsView> createState() => _AppleLineLyricsViewState();
}

class _AppleLineLyricsViewState extends State<_AppleLineLyricsView> {
  final ItemScrollController _scroll = ItemScrollController();
  int _lastIndex = -1;
  bool _pinnedOpening = false;
  // Row output depends only on (active, following, untimed) — the
  // per-tick position just selects the active line (plain rows don't
  // consume posMs for content). Caching skips rebuilding ~60 rows
  // 30×/sec; scroll side-effects below still run per tick.
  Widget? _listCache;
  int _listCacheActive = -2;
  bool _listCacheFollowing = true;
  bool _listCacheUntimed = false;

  int _activeIndex(int posMs) =>
      activeLyricLineIndex(widget.result.lines, posMs);

  void _scrollTo(int index, {bool animate = true}) {
    if (!_scroll.isAttached) return;
    if (index < 0) index = 0;
    final alignment = lyricFollowAlignment(
      index,
      compact: widget.compact,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Guarded: a stale index (lyrics swapped mid-flight) throws
      // RangeError here, which aborts the process via fail-fast.
      runGuarded('karaoke.scroll', () {
        if (!_scroll.isAttached || !mounted) return;
        if (animate) {
          _scroll.scrollTo(
            index: index,
            alignment: alignment,
            duration: WaveMotion.normal,
            curve: Curves.easeOutCubic,
          );
        } else {
          _scroll.jumpTo(index: index, alignment: alignment);
        }
      });
    });
  }

  void _pinOpeningToTop() {
    if (_pinnedOpening || !_scroll.isAttached) return;
    _pinnedOpening = true;
    _scrollTo(0, animate: false);
  }

  @override
  void didUpdateWidget(covariant _AppleLineLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result != widget.result) {
      _pinnedOpening = false;
      _lastIndex = -1;
      _listCache = null;
    }
    if (widget.following && !oldWidget.following) {
      final untimed = lyricsAreUntimed(widget.result.lines);
      _scrollTo(
        untimed ? 0 : _activeIndex(widget.positionListenable.value),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final untimed = lyricsAreUntimed(widget.result.lines);
    if (untimed) {
      // Do not rebuild on the playback clock — that remounts the list
      // and hides every line past the first screen.
      return _buildLineList(posMs: 0, active: -1, untimed: true);
    }

    return ValueListenableBuilder<int>(
      valueListenable: widget.positionListenable,
      builder: (context, posMs, _) {
        final active = _activeIndex(posMs);
        if (widget.following && _scroll.isAttached) {
          if (active <= 0 || posMs < 400) {
            _pinOpeningToTop();
            _lastIndex = active;
          } else if (active != _lastIndex) {
            final wasUninitialized = _lastIndex < 0;
            _lastIndex = active;
            _scrollTo(
              active,
              animate: !wasUninitialized && active > 0,
            );
          }
        } else if (!widget.following) {
          _lastIndex = active;
        }

        if (_listCache == null ||
            active != _listCacheActive ||
            widget.following != _listCacheFollowing ||
            untimed != _listCacheUntimed) {
          _listCacheActive = active;
          _listCacheFollowing = widget.following;
          _listCacheUntimed = untimed;
          _listCache = _buildLineList(
            posMs: posMs,
            active: active,
            untimed: false,
          );
        }
        // Mirror the highlighted line to the parent so particle bursts
        // fire on change (event-driven — only notifies when it differs).
        try {
          widget.onActiveIndexChanged?.call(active);
        } catch (_) {}
        return _wrapWithParticles(_listCache!, active: active, untimed: false);
      },
    );
  }

  Widget _wrapWithParticles(Widget list, {required int active, required bool untimed}) {
    final progress = widget.activeLineListenable;
    if (!widget.particlesEnabled || untimed || progress == null) return list;
    return Stack(
      key: widget.stackKey,
      children: [
        Positioned.fill(child: list),
        if (widget.anchorProbeBuilder != null) widget.anchorProbeBuilder!(),
        Positioned.fill(
          child: IgnorePointer(
            child: widget.particleClockScopeBuilder(
              WaveLyricParticles(
                clock: LyricParticleClock.instance.seconds,
                progress: progress,
                anchor: widget.particleAnchor,
                color: widget.particleColor,
                enabled: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLineList({
    required int posMs,
    required int active,
    required bool untimed,
  }) {
    Widget lineAt(int i) {
      final line = widget.result.lines[i];
      final isActive = i == active;
      // Isolate each row: without this, the active line's per-tick
      // repaints (highlight wipe + 16px text shadow) cascade into
      // sibling rows, re-rasterizing the whole pane ~30×/sec.
      return RepaintBoundary(
        child: Padding(
          // GlobalKey only on the active row so the particle anchor probe
          // can locate it; inactive rows keep their cheap cached widgets.
          key: isActive ? widget.activeRowKey : null,
          padding: const EdgeInsets.only(bottom: 4),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => widget.onSeekLineMs(line.timeMs),
              child: WaveKaraokeLyricLine(
                line: line,
                positionMs: posMs,
                isActive: isActive,
                isPast: !untimed && i < active,
                compact: widget.compact,
                fontSize: widget.fontSize,
                showTransliteration: widget.showTransliteration,
                karaoke: false,
                softenIdle: !untimed,
              ),
            ),
          ),
        ),
      );
    }

    final padding = EdgeInsets.fromLTRB(
      widget.compact ? 12 : 28,
      24,
      widget.compact ? 12 : 28,
      80,
    );

    final list = untimed
        ? ListView.builder(
            physics: const ClampingScrollPhysics(),
            padding: padding,
            itemCount: widget.result.lines.length,
            itemBuilder: (context, i) => lineAt(i),
          )
        : NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n is ScrollStartNotification && n.dragDetails != null) {
                widget.onUserScroll();
              }
              return false;
            },
            child: ScrollablePositionedList.builder(
              itemScrollController: _scroll,
              initialScrollIndex: 0,
              initialAlignment: 0,
              itemCount: widget.result.lines.length,
              padding: padding,
              itemBuilder: (context, i) => lineAt(i),
            ),
          );

    return Stack(
      children: [
        list,
        if (!untimed && !widget.following)
          Positioned(
            right: 16,
            bottom: 16,
            child: _ReturnToCurrentPill(onTap: widget.onResume),
          ),
      ],
    );
  }
}

class _KaraokePlainLyrics extends StatelessWidget {
  final String text;
  final bool compact;
  final bool showHeaderControls;
  final VoidCallback? onClose;

  const _KaraokePlainLyrics({
    required this.text,
    this.compact = false,
    this.showHeaderControls = true,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final dark = waveIsDark(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeaderControls)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 24,
              vertical: 8,
            ),
            child: Row(
              children: [
                Text(
                  'PLAIN LYRICS',
                  style: WaveType.overline.copyWith(
                    fontSize: 9.5,
                    color: waveAccent(context),
                  ),
                ),
                const Spacer(),
                if (onClose != null)
                  _MiniIconButton(
                    icon: WaveIcons.close,
                    onTap: onClose!,
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.all(compact ? 14 : 28),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: WaveDensity.lyricMax,
                  ),
                  child: SelectableText(
                    text,
                    style: WaveType.body.copyWith(
                      height: 1.75,
                      fontSize: compact ? 18 : 22,
                      color: dark
                          ? WaveColors.textPrimary
                          : WaveColors.lightTextPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
