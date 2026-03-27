// Request Dialog – shows request details with approve/reject/delete actions.
import 'package:flutter/material.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../application/space_ownership_service.dart';
import '../../application/space_request_service.dart';
import '../helpers/calendar_helpers.dart';
import '../theme.dart';

class RequestDialog extends StatefulWidget {
  final EventRequest request;
  final SpaceOwnershipService ownership;
  final String userOrgId;
  final UserRole userRole;
  final String Function(String) orgNameById;

  const RequestDialog({
    super.key,
    required this.request,
    required this.ownership,
    required this.userOrgId,
    required this.userRole,
    required this.orgNameById,
  });

  @override
  State<RequestDialog> createState() => _RequestDialogState();
}

class _RequestDialogState extends State<RequestDialog> {
  final _requestService = SpaceRequestService();
  bool _isProcessing = false;

  bool get _isResponder =>
      widget.userRole == UserRole.admin ||
      (widget.request.targetOrgId == widget.userOrgId &&
          widget.userRole.canRespondToRequests);

  @override
  Widget build(BuildContext context) {
    final req = widget.request;
    final isAllDay = CalendarEvent.isAllDayRange(req.requestedStart, req.requestedEnd) ||
        req.hasAllDayIntent;

    final reqByOrg = req.requestedByOrgId != null ? widget.orgNameById(req.requestedByOrgId!) : '-';
    final targetOrg = req.targetOrgId != null ? widget.orgNameById(req.targetOrgId!) : '-';

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.pending_actions, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              req.displayTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _infoRow('Tip', EventTypes.displayLabel(req.displayType)),
              _infoRow('Locație', req.eventLocation ?? 'Sala'),
              const Divider(height: 16),
              if (isAllDay) ...[
                _infoRow('Interval', 'Toată ziua'),
                _infoRow('De la', formatDateRo(req.intendedStart ?? req.requestedStart)),
                _infoRow('Până la', formatDateRo(req.intendedEnd ?? req.requestedEnd)),
              ] else ...[
                _infoRow('Data', formatDateRo(req.requestedStart)),
                _infoRow(
                  'Interval',
                  '${formatCalendarTime(req.requestedStart)} – ${formatCalendarTime(req.requestedEnd)}',
                ),
              ],
              const Divider(height: 16),
              _infoRow('Solicitat de', reqByOrg),
              _infoRow('Către', targetOrg),
              if (req.solicitantName != null && req.solicitantName!.isNotEmpty)
                _infoRow('Persoană', req.solicitantName!),
              if (req.message != null && req.message!.isNotEmpty) ...[
                const Divider(height: 16),
                const Text('Mesaj:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textMuted)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceElevated,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(req.message!, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: _buildActions(),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text('$label:', style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  List<Widget> _buildActions() {
    if (_isProcessing) {
      return [const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))];
    }

    final actions = <Widget>[];

    // Close
    actions.add(TextButton(
      onPressed: () => Navigator.of(context).pop(),
      child: const Text('Închide'),
    ));

    // Reject (responder only)
    if (_isResponder) {
      actions.add(OutlinedButton(
        onPressed: _handleReject,
        style: OutlinedButton.styleFrom(foregroundColor: AppTheme.notification),
        child: const Text('Refuză'),
      ));
    }

    // Approve (responder only)
    if (_isResponder) {
      actions.add(FilledButton(
        onPressed: _handleApprove,
        child: const Text('Acceptă'),
      ));
    }

    return actions;
  }

  Future<void> _handleApprove() async {
    setState(() => _isProcessing = true);
    try {
      await _requestService.approveRequest(widget.request, widget.ownership);
      if (mounted) Navigator.of(context).pop('accepted');
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showErrorDialog('$e');
      }
    }
  }

  Future<void> _handleReject() async {
    setState(() => _isProcessing = true);
    try {
      await _requestService.rejectRequest(widget.request, widget.ownership);
      if (mounted) Navigator.of(context).pop('rejected');
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showErrorDialog('$e');
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Atenție'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }
}
