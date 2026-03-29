import 'package:flutter/material.dart';

import '../theme.dart';

class StatusDialogHelper {
  StatusDialogHelper._();

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String message,
    bool isError = false,
  }) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              color: isError ? AppTheme.notification : AppTheme.magicPrimary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }
}
