import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chess/chess.dart' as ch;

void main() => runApp(const ChessApp());

class ChessApp extends StatelessWidget {
  const ChessApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const GameScreen(),
      );
}

// ───────────────────────── Themes ─────────────────────────
class BoardTheme {
  final String name;
  final Color light, dark;
  const BoardTheme(this.name, this.light, this.dark);
}

const boardThemes = [
  BoardTheme('Chess.com', Color(0xFFEEEED2), Color(0xFF769656)),
  BoardTheme('Wood', Color(0xFFF0D9B5), Color(0xFFB58863)),
  BoardTheme('Marble', Color(0xFFD9DEE3), Color(0xFF8A94A0)),
  BoardTheme('Ice', Color(0xFFE3F2FD), Color(0xFF64B5F6)),
  BoardTheme('Neon', Color(0xFF1E1E3F), Color(0xFF6A1B9A)),
  BoardTheme('Space', Color(0xFF263238), Color(0xFF0D1B2A)),
];

// ───────────────────────── Model ─────────────────────────
class PieceView {
  final int id;
  String type; // p n b r q k
  final bool white;
  String sq; // e.g. "e4"
  PieceView(this.id, this.type, this.white, this.sq);
}

Offset sqOffset(String sq, double s) =>
    Offset((sq.codeUnitAt(0) - 97) * s, (8 - int.parse(sq[1])) * s);

// ───────────────────────── Screen ─────────────────────────
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  late ch.Chess game;
  List<PieceView> pieces = [];
  final List<PieceView> ghosts = []; // captured pieces fading out
  int _nextId = 0;

  String? selected, lastFrom, lastTo;
  List<String> targets = [];
  int? dragId;
  Offset dragPos = Offset.zero;
  double tilt = 0;
  Timer? _tiltTimer;
  int themeIdx = 0;
  double _sq = 40;

  late final AnimationController pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void dispose() {
    pulse.dispose();
    _tiltTimer?.cancel();
    super.dispose();
  }

  // ── setup ──
  void _reset() {
    game = ch.Chess();
    _rebuildPieces();
    selected = lastFrom = lastTo = null;
    targets = [];
    dragId = null;
    ghosts.clear();
  }

  void _rebuildPieces() {
    pieces = [];
    for (var f = 0; f < 8; f++) {
      for (var r = 1; r <= 8; r++) {
        final sq = '${String.fromCharCode(97 + f)}$r';
        final p = game.get(sq);
        if (p != null) {
          pieces.add(PieceView(
              _nextId++, p.type.name, p.color == ch.Color.WHITE, sq));
        }
      }
    }
  }

  PieceView? _pieceAt(String sq) {
    for (final p in pieces) {
      if (p.sq == sq) return p;
    }
    return null;
  }

  String? _sqAt(Offset o) {
    final f = (o.dx / _sq).floor();
    final r = 7 - (o.dy / _sq).floor();
    if (f < 0 || f > 7 || r < 0 || r > 7) return null;
    return '${String.fromCharCode(97 + f)}${r + 1}';
  }

  List<String> _targetsFor(String sq) {
    final res = game.moves({'square': sq, 'asObjects': true});
    return res.map<String>((m) => (m as ch.Move).toAlgebraic).toSet().toList();
  }

  bool get _whiteTurn => game.turn == ch.Color.WHITE;
  bool get _over => game.game_over;

  String? get _checkSq {
    if (!game.in_check) return null;
    for (final p in pieces) {
      if (p.type == 'k' && p.white == _whiteTurn) return p.sq;
    }
    return null;
  }

  // ── gestures ──
  void _onDown(Offset p) {
    if (_over) return;
    final s = _sqAt(p);
    if (s == null) return;
    // tap-to-move
    if (selected != null && targets.contains(s)) {
      _tryMove(selected!, s);
      return;
    }
    final pc = _pieceAt(s);
    if (pc != null && pc.white == _whiteTurn) {
      HapticFeedback.selectionClick(); // lift
      setState(() {
        selected = s;
        targets = _targetsFor(s);
        dragId = pc.id;
        dragPos = p;
      });
    } else {
      setState(() {
        selected = null;
        targets = [];
      });
    }
  }

  void _onUpdate(DragUpdateDetails d) {
    if (dragId == null) return;
    setState(() {
      dragPos = d.localPosition;
      tilt = (d.delta.dx * 0.015).clamp(-0.06, 0.06); // wobble
    });
    _tiltTimer?.cancel();
    _tiltTimer = Timer(const Duration(milliseconds: 90), () {
      if (mounted) setState(() => tilt = 0);
    });
  }

  void _onEnd() {
    if (dragId == null) return;
    final to = _sqAt(dragPos - Offset(0, _sq * 0.5)); // where piece is shown
    final from = selected;
    if (from != null && to != null && targets.contains(to)) {
      _tryMove(from, to);
    } else {
      setState(() {
        dragId = null; // spring back
        tilt = 0;
      });
    }
  }

  // ── moves ──
  Future<void> _tryMove(String from, String to) async {
    final p = _pieceAt(from)!;
    String? promo;
    if (p.type == 'p' && (to[1] == '8' || to[1] == '1')) {
      promo = await _askPromotion(p.white) ?? 'q';
    }
    final ok = game.move({
      'from': from,
      'to': to,
      if (promo != null) 'promotion': promo,
    });
    if (ok != true) {
      setState(() => dragId = null);
      return;
    }
    // captured piece (en passant aware)
    var capSq = to;
    final isEp = p.type == 'p' && from[0] != to[0] && _pieceAt(to) == null;
    if (isEp) capSq = to[0] + from[1];
    final cap = _pieceAt(capSq);
    if (cap != null) {
      pieces.remove(cap);
      ghosts.add(cap);
      Future.delayed(const Duration(milliseconds: 450), () {
        if (mounted) setState(() => ghosts.remove(cap));
      });
    }
    // castling: move the rook too
    if (p.type == 'k' && (from.codeUnitAt(0) - to.codeUnitAt(0)).abs() == 2) {
      final king = to[0] == 'g';
      final rook = _pieceAt('${king ? 'h' : 'a'}${from[1]}');
      rook?.sq = '${king ? 'f' : 'd'}${from[1]}';
    }
    p.sq = to;
    if (promo != null) p.type = promo;

    HapticFeedback.mediumImpact(); // drop
    setState(() {
      lastFrom = from;
      lastTo = to;
      selected = null;
      targets = [];
      dragId = null;
      tilt = 0;
    });
    if (game.in_check || _over) HapticFeedback.heavyImpact();
  }

  Future<String?> _askPromotion(bool white) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: ['q', 'r', 'b', 'n']
                .map((t) => GestureDetector(
                      onTap: () => Navigator.pop(context, t),
                      child: _glyph(PieceView(-1, t, white, 'a1'), 64),
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _undo() {
    if (game.history.isEmpty) return;
    game.undo_move();
    setState(() {
      _rebuildPieces();
      selected = lastFrom = lastTo = null;
      targets = [];
    });
  }

  String get _status {
    if (game.in_checkmate) return 'كش مات! ${_whiteTurn ? 'الأسود' : 'الأبيض'} فاز 🏆';
    if (game.in_stalemate) return 'تعادل: جمود (Stalemate)';
    if (game.in_threefold_repetition) return 'تعادل: تكرار 3 مرات';
    if (game.insufficient_material) return 'تعادل: مواد غير كافية';
    if (game.in_draw) return 'تعادل';
    final t = _whiteTurn ? 'دور الأبيض' : 'دور الأسود';
    return game.in_check ? '$t — كش! ⚠️' : t;
  }

  // ── UI ──
  static const _glyphs = {
    'k': '♚', 'q': '♛', 'r': '♜', 'b': '♝', 'n': '♞', 'p': '♟'
  };

  Widget _glyph(PieceView p, double size) {
    final g = '${_glyphs[p.type]}\uFE0E';
    final fs = size * 0.82;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        Text(g,
            style: TextStyle(
              fontSize: fs,
              height: 1,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2.5
                ..color = p.white ? Colors.black87 : Colors.white60,
            )),
        Text(g,
            style: TextStyle(
              fontSize: fs,
              height: 1,
              color: p.white ? Colors.white : const Color(0xFF1B1B1B),
            )),
      ]),
    );
  }

  Widget _pieceWidget(PieceView p) {
    final dragging = p.id == dragId;
    final off = dragging
        ? Offset(dragPos.dx - _sq / 2, dragPos.dy - _sq * 1.5)
        : sqOffset(p.sq, _sq);
    return AnimatedPositioned(
      key: ValueKey(p.id),
      duration: dragging ? Duration.zero : const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      left: off.dx,
      top: off.dy,
      width: _sq,
      height: _sq,
      child: IgnorePointer(
        child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
          if (dragging) // moving shadow under the lifted piece
            Positioned(
              top: _sq * 0.62,
              child: Container(
                width: _sq * 0.7,
                height: _sq * 0.22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_sq),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 14)
                  ],
                ),
              ),
            ),
          AnimatedScale(
            scale: dragging ? 1.4 : 1,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutBack,
            child: AnimatedRotation(
              turns: dragging ? tilt : 0,
              duration: const Duration(milliseconds: 120),
              child: _glyph(p, _sq),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _ghost(PieceView p) {
    final o = sqOffset(p.sq, _sq);
    return Positioned(
      key: ValueKey('ghost${p.id}'),
      left: o.dx,
      top: o.dy,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 400),
          builder: (_, v, child) => Opacity(
            opacity: 1 - v,
            child: Transform.scale(scale: 1 + v * 0.6, child: child),
          ),
          child: _glyph(p, _sq),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = boardThemes[themeIdx];
    final captures = targets.where((t) => _pieceAt(t) != null).toSet();
    final dragged = pieces.where((p) => p.id == dragId).toList();
    final others = pieces.where((p) => p.id != dragId).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF262421),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Chess'),
        actions: [
          IconButton(
              icon: const Icon(Icons.palette),
              tooltip: theme.name,
              onPressed: () =>
                  setState(() => themeIdx = (themeIdx + 1) % boardThemes.length)),
          IconButton(icon: const Icon(Icons.undo), onPressed: _undo),
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(_reset)),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(_status,
                  key: ValueKey(_status),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.all(8),
              child: AspectRatio(
                aspectRatio: 1,
                child: LayoutBuilder(builder: (context, c) {
                  _sq = c.maxWidth / 8;
                  return GestureDetector(
                    onPanDown: (d) => _onDown(d.localPosition),
                    onPanUpdate: _onUpdate,
                    onPanEnd: (_) => _onEnd(),
                    onPanCancel: () {
                      if (dragId != null) setState(() => dragId = null);
                    },
                    child: Container(
                      decoration: BoxDecoration(boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 18)
                      ]),
                      child: Stack(clipBehavior: Clip.none, children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: BoardPainter(
                              theme: theme,
                              pulse: pulse,
                              lastFrom: lastFrom,
                              lastTo: lastTo,
                              selected: selected,
                              targets: targets,
                              captures: captures,
                              checkSq: _checkSq,
                            ),
                          ),
                        ),
                        ...ghosts.map(_ghost),
                        ...others.map(_pieceWidget),
                        ...dragged.map(_pieceWidget), // on top
                      ]),
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 8),
            Text('الثيم: ${theme.name}',
                style: const TextStyle(color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Painter ─────────────────────────
class BoardPainter extends CustomPainter {
  final BoardTheme theme;
  final Animation<double> pulse;
  final String? lastFrom, lastTo, selected, checkSq;
  final List<String> targets;
  final Set<String> captures;

  BoardPainter({
    required this.theme,
    required this.pulse,
    this.lastFrom,
    this.lastTo,
    this.selected,
    this.checkSq,
    required this.targets,
    required this.captures,
  }) : super(repaint: pulse);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 8;
    final paint = Paint();

    for (var f = 0; f < 8; f++) {
      for (var r = 0; r < 8; r++) {
        paint.color = (f + r) % 2 == 0 ? theme.dark : theme.light;
        canvas.drawRect(Rect.fromLTWH(f * s, (7 - r) * s, s, s), paint);
      }
    }

    Rect rectOf(String sq) {
      final o = sqOffset(sq, s);
      return Rect.fromLTWH(o.dx, o.dy, s, s);
    }

    // last move glow
    for (final sq in [lastFrom, lastTo]) {
      if (sq == null) continue;
      canvas.drawRect(
          rectOf(sq), Paint()..color = const Color(0xFFFFEB3B).withOpacity(0.35));
    }
    if (selected != null) {
      canvas.drawRect(rectOf(selected!),
          Paint()..color = const Color(0xFF42A5F5).withOpacity(0.45));
    }

    // check glow (pulsing red)
    if (checkSq != null) {
      final r = rectOf(checkSq!);
      canvas.drawCircle(
        r.center,
        s * (0.55 + 0.15 * pulse.value),
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.red.withOpacity(0.85),
            Colors.red.withOpacity(0),
          ]).createShader(Rect.fromCircle(center: r.center, radius: s * 0.7)),
      );
    }

    // legal move hints (pulsing)
    for (final t in targets) {
      final c = rectOf(t).center;
      if (captures.contains(t)) {
        canvas.drawCircle(
            c,
            s * (0.44 + 0.03 * pulse.value),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = s * 0.08
              ..color = Colors.black.withOpacity(0.35));
      } else {
        canvas.drawCircle(c, s * (0.15 + 0.04 * pulse.value),
            Paint()..color = Colors.black.withOpacity(0.28));
      }
    }

    // coordinates
    for (var i = 0; i < 8; i++) {
      _label(canvas, String.fromCharCode(97 + i),
          Offset(i * s + s * 0.78, 7 * s + s * 0.74), s, i % 2 == 0 ? theme.light : theme.dark);
      _label(canvas, '${8 - i}', Offset(s * 0.04, i * s + s * 0.02), s,
          i % 2 == 0 ? theme.dark : theme.light);
    }
  }

  void _label(Canvas c, String t, Offset o, double s, Color col) {
    final tp = TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(
              fontSize: s * 0.2, fontWeight: FontWeight.bold, color: col)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant BoardPainter old) => true;
}
