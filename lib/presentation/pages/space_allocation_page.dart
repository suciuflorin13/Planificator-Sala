// Space Allocation Page – weekly override editing for admin users.
import 'package:flutter/material.dart';
import '../../domain/models.dart';
import '../../application/space_ownership_service.dart';
import '../theme.dart';
import '../helpers/calendar_helpers.dart';

// ── Result / Draft models ──

class SpaceAllocResult {
  final DateTime weekStart;
  final List<Map<int, DayAllocationDraft>> blocks;
  const SpaceAllocResult({required this.weekStart, required this.blocks});
}

class DayAllocationDraft {
  final List<SegmentDraft> segments;
  const DayAllocationDraft({required this.segments});
}

class SegmentDraft {
  final int startHour;
  final int endHour;
  final String? orgId;
  const SegmentDraft({required this.startHour, required this.endHour, this.orgId});
}

// ── Timeline constants ──
const int _kTimelineStart = 9;
const int _kTimelineEnd = 23;
const int _kTimelineSpan = _kTimelineEnd - _kTimelineStart; // 14 hours

// ── Page ──

class SpaceAllocationPage extends StatefulWidget {
  final DateTime initialWeekStart;
  final SpaceOwnershipService ownership;
  final List<Organization> organizations;
  final List<CalendarEvent> weekEvents;

  const SpaceAllocationPage({
    super.key,
    required this.initialWeekStart,
    required this.ownership,
    required this.organizations,
    this.weekEvents = const [],
  });

  @override
  State<SpaceAllocationPage> createState() => _SpaceAllocationPageState();
}

class _SpaceAllocationPageState extends State<SpaceAllocationPage> {
  late DateTime _weekStart;
  // weekday (1-7) → list of boundary hours [9, h1, h2, ..., 23]
  // segments are between consecutive boundary values
  late Map<int, List<int>> _dayBoundaries;
  // weekday → list of orgId per segment (length = boundaries.length - 1)
  late Map<int, List<String?>> _dayOwners;

  String? _magicId;
  String? _maidanId;

  @override
  void initState() {
    super.initState();
    _weekStart = widget.initialWeekStart;
    _magicId = widget.ownership.magicId;
    _maidanId = widget.ownership.maidanId;
    _initFromOwnership();
  }

  void _initFromOwnership() {
    _dayBoundaries = {};
    _dayOwners = {};
    for (int wd = 1; wd <= 7; wd++) {
      final segs = _buildDayFromOwnership(wd);
      _applySegments(wd, segs);
    }
  }

  List<SegmentDraft> _buildDayFromOwnership(int weekday) {
    final date = _weekStart.add(Duration(days: weekday - 1));
    final segments = <SegmentDraft>[];
    int hour = _kTimelineStart;
    String? currentOwner = widget.ownership.getOwnerAt(DateTime(date.year, date.month, date.day, hour));
    int segStart = hour;

    for (int h = _kTimelineStart + 1; h <= _kTimelineEnd; h++) {
      final owner = h < _kTimelineEnd
          ? widget.ownership.getOwnerAt(DateTime(date.year, date.month, date.day, h))
          : null;
      if (h == _kTimelineEnd || owner != currentOwner) {
        segments.add(SegmentDraft(startHour: segStart, endHour: h, orgId: currentOwner));
        currentOwner = owner;
        segStart = h;
      }
    }
    return segments;
  }

  void _applySegments(int wd, List<SegmentDraft> segs) {
    if (segs.isEmpty) {
      _dayBoundaries[wd] = [_kTimelineStart, _kTimelineEnd];
      _dayOwners[wd] = [null];
      return;
    }
    final boundaries = <int>[segs.first.startHour];
    final owners = <String?>[];
    for (final s in segs) {
      owners.add(s.orgId);
      boundaries.add(s.endHour);
    }
    _dayBoundaries[wd] = boundaries;
    _dayOwners[wd] = owners;
  }

  List<SegmentDraft> _toSegments(int wd) {
    final b = _dayBoundaries[wd]!;
    final o = _dayOwners[wd]!;
    return [
      for (int i = 0; i < o.length; i++)
        SegmentDraft(startHour: b[i], endHour: b[i + 1], orgId: o[i])
    ];
  }

  void _changeWeek(int delta) {
    setState(() {
      _weekStart = _weekStart.add(Duration(days: 7 * delta));
      _initFromOwnership();
    });
  }

  void _setDefaultPattern() {
    setState(() {
      for (int wd = 1; wd <= 7; wd++) {
        List<SegmentDraft> segs;
        if (wd == 1 || wd == 3) {
          // Mon, Wed: 9-16 Magic, 16-23 Maidan
          segs = [
            SegmentDraft(startHour: 9, endHour: 16, orgId: _magicId),
            SegmentDraft(startHour: 16, endHour: 23, orgId: _maidanId),
          ];
        } else if (wd == 2 || wd == 4) {
          // Tue, Thu: 9-16 Maidan, 16-23 Magic
          segs = [
            SegmentDraft(startHour: 9, endHour: 16, orgId: _maidanId),
            SegmentDraft(startHour: 16, endHour: 23, orgId: _magicId),
          ];
        } else {
          // Fri, Sat, Sun: full Magic
          segs = [SegmentDraft(startHour: 9, endHour: 23, orgId: _magicId)];
        }
        _applySegments(wd, segs);
      }
    });
  }

  void _invertAll() {
    setState(() {
      for (int wd = 1; wd <= 7; wd++) {
        final owners = _dayOwners[wd]!;
        _dayOwners[wd] = owners.map((id) {
          if (id == _magicId) return _maidanId;
          if (id == _maidanId) return _magicId;
          return id;
        }).toList();
      }
    });
  }

  void _toggleSegmentOwner(int wd, int segIndex) {
    setState(() {
      final owners = List<String?>.from(_dayOwners[wd]!);
      final current = owners[segIndex];
      if (current == _magicId) {
        owners[segIndex] = _maidanId;
      } else if (current == _maidanId) {
        owners[segIndex] = null; // free
      } else {
        owners[segIndex] = _magicId;
      }
      _dayOwners[wd] = owners;
    });
  }

  void _addSplit(int wd) {
    final b = List<int>.from(_dayBoundaries[wd]!);
    final o = List<String?>.from(_dayOwners[wd]!);
    // Find the longest segment and split it in the middle
    int bestIdx = 0;
    int bestLen = 0;
    for (int i = 0; i < o.length; i++) {
      final len = b[i + 1] - b[i];
      if (len > bestLen) {
        bestLen = len;
        bestIdx = i;
      }
    }
    if (bestLen < 2) return; // can't split 1-hour segment
    final mid = b[bestIdx] + (bestLen ~/ 2);
    b.insert(bestIdx + 1, mid);
    o.insert(bestIdx + 1, o[bestIdx]);
    setState(() {
      _dayBoundaries[wd] = b;
      _dayOwners[wd] = o;
    });
  }

  void _moveBoundary(int wd, int boundaryIndex, double fraction) {
    // boundaryIndex is 1..boundaries.length-2 (interior boundaries only)
    final b = List<int>.from(_dayBoundaries[wd]!);
    final newHour = (_kTimelineStart + fraction * _kTimelineSpan).round().clamp(
          b[boundaryIndex - 1] + 1,
          b[boundaryIndex + 1] - 1,
        );
    setState(() {
      b[boundaryIndex] = newHour;
      _dayBoundaries[wd] = b;
    });
  }

  Color _colorForOrg(String? orgId) {
    if (orgId == _magicId) return AppTheme.magicPrimary;
    if (orgId == _maidanId) return AppTheme.maidanPrimary;
    return AppTheme.freeSlot;
  }

  String _orgLabel(String? orgId) {
    if (orgId == null) return 'Liber';
    for (final org in widget.organizations) {
      if (org.id == orgId) return org.name;
    }
    return 'Necunoscut';
  }

  List<CalendarEvent> _eventsForDay(int wd) {
    final date = _weekStart.add(Duration(days: wd - 1));
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    return widget.weekEvents.where((e) {
      return e.startTime.isBefore(dayEnd) && e.endTime.isAfter(dayStart);
    }).toList();
  }

  void _save() {
    final blocks = <Map<int, DayAllocationDraft>>[];
    final block = <int, DayAllocationDraft>{};
    for (int wd = 1; wd <= 7; wd++) {
      block[wd] = DayAllocationDraft(segments: _toSegments(wd));
    }
    blocks.add(block);

    Navigator.of(context).pop(SpaceAllocResult(
      weekStart: _weekStart,
      blocks: blocks,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final dayNames = ['Luni', 'Marți', 'Miercuri', 'Joi', 'Vineri', 'Sâmbătă', 'Duminică'];

    return Scaffold(
      backgroundColor: AppTheme.appBg,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        foregroundColor: AppTheme.textPrimary,
        title: const Text('Împărțire Spațiu', style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz, color: AppTheme.textPrimary),
            tooltip: 'Inversează (Magic ↔ Maidan)',
            onPressed: _invertAll,
          ),
          IconButton(
            icon: const Icon(Icons.restore, color: AppTheme.textPrimary),
            tooltip: 'Setare implicită',
            onPressed: _setDefaultPattern,
          ),
        ],
      ),
      body: Column(
        children: [
          // Week navigator
          Container(
            color: AppTheme.surfaceElevated,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left, color: AppTheme.textPrimary),
                  onPressed: () => _changeWeek(-1),
                ),
                Text(
                  'Săptămâna ${formatDateRo(_weekStart)} – ${formatDateRo(_weekStart.add(const Duration(days: 6)))}',
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.textPrimary),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, color: AppTheme.textPrimary),
                  onPressed: () => _changeWeek(1),
                ),
              ],
            ),
          ),
          // Legend
          Container(
            color: AppTheme.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                _LegendDot(color: AppTheme.magicPrimary, label: 'Magic Puppet'),
                const SizedBox(width: 16),
                _LegendDot(color: AppTheme.maidanPrimary, label: 'Maidan'),
                const SizedBox(width: 16),
                _LegendDot(color: AppTheme.freeSlot, label: 'Liber'),
                const SizedBox(width: 16),
                _LegendDot(color: AppTheme.magicEvent, label: 'Ev. Magic', isDiamond: true),
                const SizedBox(width: 12),
                _LegendDot(color: AppTheme.maidanEvent, label: 'Ev. Maidan', isDiamond: true),
                const Spacer(),
                Text(
                  'Clic pe segment = schimbă proprietar',
                  style: const TextStyle(fontSize: 10, color: AppTheme.textMuted, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          // Hour axis header
          Padding(
            padding: const EdgeInsets.only(left: 80, right: 40, top: 4),
            child: _HourAxisHeader(),
          ),
          // Day rows
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                children: List.generate(7, (i) {
                  final wd = i + 1;
                  final date = _weekStart.add(Duration(days: i));
                  return _DayTimelineRow(
                    dayName: dayNames[i],
                    date: date,
                    boundaries: _dayBoundaries[wd]!,
                    owners: _dayOwners[wd]!,
                    events: _eventsForDay(wd),
                    magicId: _magicId,
                    maidanId: _maidanId,
                    colorForOrg: _colorForOrg,
                    orgLabel: _orgLabel,
                    onToggleOwner: (idx) => _toggleSegmentOwner(wd, idx),
                    onMoveBoundary: (bIdx, frac) => _moveBoundary(wd, bIdx, frac),
                    onAddSplit: () => _addSplit(wd),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.surfaceElevated),
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Salvează împărțirea'),
          ),
        ),
      ),
    );
  }
}

// ── Hour axis header ──

class _HourAxisHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      return SizedBox(
        height: 18,
        child: Stack(
          children: [
            for (int h = _kTimelineStart; h <= _kTimelineEnd; h++)
              Positioned(
                left: ((h - _kTimelineStart) / _kTimelineSpan) * w - 12,
                child: Text(
                  '$h',
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      );
    });
  }
}

// ── Day timeline row ──

class _DayTimelineRow extends StatelessWidget {
  final String dayName;
  final DateTime date;
  final List<int> boundaries;
  final List<String?> owners;
  final List<CalendarEvent> events;
  final String? magicId;
  final String? maidanId;
  final Color Function(String?) colorForOrg;
  final String Function(String?) orgLabel;
  final void Function(int segIndex) onToggleOwner;
  final void Function(int boundaryIndex, double fraction) onMoveBoundary;
  final VoidCallback onAddSplit;

  const _DayTimelineRow({
    required this.dayName,
    required this.date,
    required this.boundaries,
    required this.owners,
    required this.events,
    this.magicId,
    this.maidanId,
    required this.colorForOrg,
    required this.orgLabel,
    required this.onToggleOwner,
    required this.onMoveBoundary,
    required this.onAddSplit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Day label
            SizedBox(
              width: 64,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(dayName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  Text(
                    '${date.day}.${date.month.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: onAddSplit,
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppTheme.border),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.add, size: 10, color: AppTheme.textMuted),
                          const Text(' seg', style: TextStyle(fontSize: 9, color: AppTheme.textMuted)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            // Timeline
            Expanded(
              child: _TimelineWidget(
                boundaries: boundaries,
                owners: owners,
                events: events,
                magicId: magicId,
                colorForOrg: colorForOrg,
                orgLabel: orgLabel,
                onToggleOwner: onToggleOwner,
                onMoveBoundary: onMoveBoundary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Timeline widget with draggable handles ──

class _TimelineWidget extends StatefulWidget {
  final List<int> boundaries;
  final List<String?> owners;
  final List<CalendarEvent> events;
  final String? magicId;
  final Color Function(String?) colorForOrg;
  final String Function(String?) orgLabel;
  final void Function(int segIndex) onToggleOwner;
  final void Function(int boundaryIndex, double fraction) onMoveBoundary;

  const _TimelineWidget({
    required this.boundaries,
    required this.owners,
    required this.events,
    this.magicId,
    required this.colorForOrg,
    required this.orgLabel,
    required this.onToggleOwner,
    required this.onMoveBoundary,
  });

  @override
  State<_TimelineWidget> createState() => _TimelineWidgetState();
}

class _TimelineWidgetState extends State<_TimelineWidget> {
  // dragging state
  int? _draggingBoundary; // index into boundaries (1..length-2)
  double? _dragFraction;

  double _hourToFraction(int hour) => (hour - _kTimelineStart) / _kTimelineSpan;

  int _fractionToHour(double f) =>
      (_kTimelineStart + (f * _kTimelineSpan).round()).clamp(_kTimelineStart, _kTimelineEnd);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final totalW = constraints.maxWidth;

      // Effective boundaries considering live drag
      List<int> effectiveBoundaries = List.from(widget.boundaries);
      if (_draggingBoundary != null && _dragFraction != null) {
        final newHour = _fractionToHour(_dragFraction!).clamp(
          effectiveBoundaries[_draggingBoundary! - 1] + 1,
          effectiveBoundaries[_draggingBoundary! + 1] - 1,
        );
        effectiveBoundaries = List.from(effectiveBoundaries);
        effectiveBoundaries[_draggingBoundary!] = newHour;
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (details) {
          final frac = details.localPosition.dx / totalW;
          // find nearest interior boundary
          int? nearest;
          double nearestDist = 20 / totalW; // 20px threshold
          for (int i = 1; i < widget.boundaries.length - 1; i++) {
            final bf = _hourToFraction(widget.boundaries[i]);
            final dist = (frac - bf).abs();
            if (dist < nearestDist) {
              nearestDist = dist;
              nearest = i;
            }
          }
          if (nearest != null) {
            setState(() {
              _draggingBoundary = nearest;
              _dragFraction = frac;
            });
          }
        },
        onHorizontalDragUpdate: (details) {
          if (_draggingBoundary == null) return;
          setState(() {
            _dragFraction = (details.localPosition.dx / totalW).clamp(0.0, 1.0);
          });
        },
        onHorizontalDragEnd: (_) {
          if (_draggingBoundary != null && _dragFraction != null) {
            widget.onMoveBoundary(_draggingBoundary!, _dragFraction!);
          }
          setState(() {
            _draggingBoundary = null;
            _dragFraction = null;
          });
        },
        child: SizedBox(
          height: 62,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Segment blocks
              Positioned.fill(
                child: Row(
                  children: [
                    for (int i = 0; i < widget.owners.length; i++)
                      Builder(builder: (ctx) {
                        final bStart = effectiveBoundaries[i];
                        final bEnd = effectiveBoundaries[i + 1];
                        final frac = (bEnd - bStart) / _kTimelineSpan;
                        final orgId = widget.owners[i];
                        final baseColor = widget.colorForOrg(orgId);
                        final isFirst = i == 0;
                        final isLast = i == widget.owners.length - 1;
                        return Expanded(
                          flex: (frac * 1000).round(),
                          child: GestureDetector(
                            onTap: () => widget.onToggleOwner(i),
                            child: Tooltip(
                              message:
                                  '${widget.orgLabel(orgId)} ($bStart:00–$bEnd:00)\nClic pentru a schimba proprietarul',
                              child: Container(
                                margin: EdgeInsets.only(
                                  left: isFirst ? 0 : 0.5,
                                  right: isLast ? 0 : 0.5,
                                ),
                                decoration: BoxDecoration(
                                  color: baseColor.withAlpha(225),
                                  border: Border.all(color: Colors.white.withAlpha(60), width: 0.8),
                                  borderRadius: BorderRadius.horizontal(
                                    left: isFirst ? const Radius.circular(6) : Radius.zero,
                                    right: isLast ? const Radius.circular(6) : Radius.zero,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      widget.orgLabel(orgId),
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '$bStart–$bEnd',
                                      style: const TextStyle(color: Colors.white70, fontSize: 8),
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
              // Event overlay blocks (no text, semi-transparent)
              for (final event in widget.events) ...[
                _buildEventOverlay(event, totalW),
              ],
              // Drag handles for interior boundaries
              for (int bi = 1; bi < effectiveBoundaries.length - 1; bi++)
                _buildHandle(bi, effectiveBoundaries[bi], totalW),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildEventOverlay(CalendarEvent event, double totalW) {
    final dayStart = DateTime(event.startTime.year, event.startTime.month, event.startTime.day, _kTimelineStart);
    final dayEnd = DateTime(event.startTime.year, event.startTime.month, event.startTime.day, _kTimelineEnd);

    final evStart = event.startTime.isBefore(dayStart) ? dayStart : event.startTime;
    final evEnd = event.endTime.isAfter(dayEnd) ? dayEnd : event.endTime;

    final startMinutes = evStart.difference(dayStart).inMinutes;
    final endMinutes = evEnd.difference(dayStart).inMinutes;
    final totalMinutes = (_kTimelineSpan * 60).toDouble();

    if (endMinutes <= 0 || startMinutes >= totalMinutes.toInt()) return const SizedBox.shrink();

    final left = (startMinutes / totalMinutes) * totalW;
    final width = ((endMinutes - startMinutes) / totalMinutes) * totalW;

    // Distinct event lane color per organization
    final isMagic = event.organizationId == widget.magicId;
    final orgColor = isMagic ? AppTheme.magicEvent : AppTheme.maidanEvent;

    return Positioned(
      left: left.clamp(0, totalW - 2),
      width: width.clamp(2, totalW),
      // Keep event blocks in a dedicated lower lane so they are always visible
      top: 42,
      height: 14,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [orgColor.withAlpha(210), orgColor.withAlpha(170)],
            ),
            border: Border.all(color: Colors.white.withAlpha(180), width: 1.0),
            borderRadius: BorderRadius.circular(3),
            boxShadow: [
              BoxShadow(color: orgColor.withAlpha(80), blurRadius: 6, offset: const Offset(0, 1)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: CustomPaint(
              painter: _EventPatternPainter(isMagic: isMagic),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHandle(int boundaryIndex, int hour, double totalW) {
    final frac = _hourToFraction(hour);
    final isDragging = _draggingBoundary == boundaryIndex;

    return Positioned(
      left: frac * totalW - 8,
      top: 2,
      bottom: 14,
      child: Center(
        child: Container(
          width: 16,
          height: 40,
          decoration: BoxDecoration(
            color: isDragging ? Colors.white : Colors.white.withAlpha(210),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isDragging ? Colors.black87 : Colors.black38,
              width: isDragging ? 2 : 1,
            ),
            boxShadow: [BoxShadow(color: Colors.black.withAlpha(60), blurRadius: 4)],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 2, height: 12, color: Colors.black45, margin: const EdgeInsets.symmetric(horizontal: 4)),
              const SizedBox(height: 2),
              Container(width: 2, height: 6, color: Colors.black38, margin: const EdgeInsets.symmetric(horizontal: 4)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventPatternPainter extends CustomPainter {
  final bool isMagic;
  const _EventPatternPainter({required this.isMagic});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withAlpha(120);

    if (isMagic) {
      // Magic: diagonal forward stripes
      const step = 6.0;
      for (double x = -size.height; x < size.width + size.height; x += step) {
        canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
      }
    } else {
      // Maidan: subtle checker grid
      const step = 6.0;
      for (double x = 0; x <= size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
      for (double y = 0; y <= size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EventPatternPainter oldDelegate) {
    return oldDelegate.isMagic != isMagic;
  }
}

// ── Legend dot ──

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool isDiamond;
  const _LegendDot({required this.color, required this.label, this.isDiamond = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        isDiamond
            ? Transform.rotate(
                angle: 0.785,
                child: Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
              )
            : Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

