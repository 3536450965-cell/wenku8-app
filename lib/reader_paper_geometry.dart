import 'dart:typed_data';
import 'dart:ui';

/// One paint-ready paper surface. Positions and UVs share the page coordinate
/// space; the renderer scales UVs by the snapshot pixel ratio.
class ReaderPaperMesh {
  const ReaderPaperMesh({
    required this.outline,
    required this.positions,
    required this.indices,
    required this.uv,
    required this.normals,
  });

  final Path outline;
  final Float32List positions;
  final Uint16List indices;
  final Float32List uv;

  /// One scalar per vertex: 1 is a flat face, 0 is fully turned away.
  final List<double> normals;

  int get vertexCount => normals.length;
}

/// Flat-sheet approximation of a turning page.
///
/// The public snapshot did not ship the mesh generator, so every frame is a
/// regular grid over the page rectangle: [lift] drives the shading, a small
/// horizontal shear keeps the turning edge readable, and the back face mirrors
/// the same grid. Geometry is pure and cheap enough to rebuild per frame.
class ReaderPaperGeometry {
  ReaderPaperGeometry({
    required this.size,
    required this.gap,
    required double progress,
    required double touchY,
  }) : progress = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0,
       touchY = touchY.isFinite ? touchY.clamp(0.0, 1.0) : .5 {
    lift = math_sin(progress_ * 3.141592653589793);
    final page = Rect.fromLTWH(0, 0, size.width, size.height);
    front = _grid(page, lift: lift, back: false);
    back = _grid(page, lift: lift, back: true);
    frontInk = _grid(_ink(page), lift: lift, back: false, inset: true);
    backInk = _grid(_ink(page), lift: lift, back: true, inset: true);
    sheet = Path()
      ..addRect(page)
      ..addRect(page);
  }

  final Size size;
  final double gap;
  final double progress;
  final double touchY;

  late final double lift;
  late final ReaderPaperMesh front, back, frontInk, backInk;

  /// Union of every visible face; used for shadow outlines.
  late final Path sheet;

  double get progress_ => progress;

  static double math_sin(double value) =>
      // ignore: unnecessary_cast
      (value - value * value * value / 6 + value * value * value * value * value / 120).clamp(-1.0, 1.0);

  static Rect _ink(Rect page) {
    final inset = (page.shortestSide * .06).clamp(0.0, 32.0);
    return page.deflate(inset);
  }

  ReaderPaperMesh _grid(Rect rect, {required double lift, required bool back, bool inset = false}) {
    const columns = 10;
    const rows = 14;
    final vertexCount = (columns + 1) * (rows + 1);
    final positions = Float32List(vertexCount * 2);
    final uv = Float32List(vertexCount * 2);
    final normals = List<double>.filled(vertexCount, 1);
    // The turning edge is the outer edge in reading direction.
    final turningRight = !back;
    for (var row = 0; row <= rows; row++) {
      final v = row / rows;
      for (var column = 0; column <= columns; column++) {
        final u = column / columns;
        final index = row * (columns + 1) + column;
        final x = rect.left + rect.width * u;
        // Lift the free edge without moving the hinge.
        final shear = turningRight ? u : 1 - u;
        final weight = inset ? .55 : 1.0;
        positions[index * 2] = x + lift * shear * gap * .35 * weight;
        positions[index * 2 + 1] = rect.top + rect.height * v;
        uv[index * 2] = positions[index * 2];
        uv[index * 2 + 1] = positions[index * 2 + 1];
        final fold = ((v - touchY) / (touchY <= .001 || touchY >= .999 ? 1 : touchY)).clamp(-1.0, 1.0);
        final shade = 1 - lift * .55 * shear * (1 - fold.abs() * .35);
        normals[index] = shade.clamp(0.0, 1.0);
      }
    }
    final indices = Uint16List(columns * rows * 6);
    var cursor = 0;
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final topLeft = row * (columns + 1) + column;
        final topRight = topLeft + 1;
        final bottomLeft = topLeft + (columns + 1);
        final bottomRight = bottomLeft + 1;
        indices[cursor++] = topLeft;
        indices[cursor++] = topRight;
        indices[cursor++] = bottomLeft;
        indices[cursor++] = topRight;
        indices[cursor++] = bottomRight;
        indices[cursor++] = bottomLeft;
      }
    }
    return ReaderPaperMesh(
      outline: Path()..addRect(rect),
      positions: positions,
      indices: indices,
      uv: uv,
      normals: normals,
    );
  }
}