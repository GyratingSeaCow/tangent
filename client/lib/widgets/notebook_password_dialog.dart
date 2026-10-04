// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

/// Asks for a new notebook password twice. Null means cancel.
Future<String?> showSetNotebookPasswordDialog(
  BuildContext context, {
  required String notebookTitle,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) =>
        _SetPasswordDialog(notebookTitle: notebookTitle),
  );
}

/// Requires a password and resolves only after [verify] accepts it.
///
/// A wrong password leaves the dialog open and never calls the protected
/// action. Null/cancel is represented by false.
Future<bool> showNotebookUnlockDialog(
  BuildContext context, {
  required String notebookTitle,
  required Future<bool> Function(String password) verify,
  String title = 'Unlock notebook',
  String confirmLabel = 'Unlock',
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => _VerifyPasswordDialog(
          notebookTitle: notebookTitle,
          title: title,
          confirmLabel: confirmLabel,
          verify: verify,
        ),
      ) ??
      false;
}

class _SetPasswordDialog extends StatefulWidget {
  const _SetPasswordDialog({required this.notebookTitle});

  final String notebookTitle;

  @override
  State<_SetPasswordDialog> createState() => _SetPasswordDialogState();
}

class _SetPasswordDialogState extends State<_SetPasswordDialog> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final String password = _password.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter a password');
      return;
    }
    if (_confirm.text != password) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Turn on password protection'),
    content: AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.notebookTitle.isEmpty
                ? 'Protect this notebook.'
                : 'Protect “${widget.notebookTitle}”.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('notebook-new-password'),
            controller: _password,
            obscureText: true,
            autofocus: true,
            autofillHints: const <String>[AutofillHints.newPassword],
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          TextField(
            key: const ValueKey<String>('notebook-confirm-password'),
            controller: _confirm,
            obscureText: true,
            autofillHints: const <String>[AutofillHints.newPassword],
            decoration: const InputDecoration(
              labelText: 'Enter password again',
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              key: const ValueKey<String>('notebook-password-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey<String>('notebook-password-enable'),
        onPressed: _submit,
        child: const Text('Turn on'),
      ),
    ],
  );
}

class _VerifyPasswordDialog extends StatefulWidget {
  const _VerifyPasswordDialog({
    required this.notebookTitle,
    required this.title,
    required this.confirmLabel,
    required this.verify,
  });

  final String notebookTitle;
  final String title;
  final String confirmLabel;
  final Future<bool> Function(String password) verify;

  @override
  State<_VerifyPasswordDialog> createState() => _VerifyPasswordDialogState();
}

class _VerifyPasswordDialogState extends State<_VerifyPasswordDialog> {
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter the password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final bool accepted = await widget.verify(_password.text);
    if (!mounted) return;
    if (accepted) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = 'Wrong password';
      _password
        ..clear()
        ..selection = const TextSelection.collapsed(offset: 0);
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.notebookTitle.isEmpty
              ? 'This notebook is protected.'
              : '“${widget.notebookTitle}” is protected.',
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey<String>('notebook-current-password'),
          controller: _password,
          autofocus: true,
          enabled: !_busy,
          obscureText: true,
          autofillHints: const <String>[AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _error!,
            key: const ValueKey<String>('notebook-password-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey<String>('notebook-password-submit'),
        onPressed: _busy ? null : _submit,
        child: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(widget.confirmLabel),
      ),
    ],
  );
}
