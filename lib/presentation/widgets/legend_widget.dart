// Legend widget – shows color key for the calendar.
import 'package:flutter/material.dart';
import '../theme.dart';

class CalendarLegend extends StatelessWidget {
  const CalendarLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: const Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          _LegendChip(label: 'Magic Puppet', color: AppTheme.magicPrimary),
          _LegendChip(label: 'Maidan', color: AppTheme.maidanPrimary),
          _LegendChip(label: 'Liber', color: AppTheme.freeSlot),
          _LegendChip(label: 'Cerere trimisă', color: AppTheme.requestCreated),
          _LegendChip(label: 'Cerere primită', color: AppTheme.requestReceived),
        ],
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  final String label;
  final Color color;
  const _LegendChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
