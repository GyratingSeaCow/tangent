// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/widgets.dart';

/// Desktop parity for long-press: the same action on mouse right-click.
///
/// The app's mobile idiom is long-press (enter selection, folder actions).
/// With a mouse that gesture is awkward and undiscoverable — the desktop
/// idiom for "context action on this thing" is the secondary button. Every
/// long-press site passes its handler through here to get the matching
/// onSecondaryTap, so the two inputs can never drift apart:
///
///     InkWell(
///       onLongPress: handler,
///       onSecondaryTap: secondaryTapFor(handler),
///       ...
///
/// Null in, null out: a disabled long-press (selection already active, the
/// 'No folder' pseudo-header) must not leave a live right-click behind.
///
/// Kept platform-unconditional on purpose. On touch devices no secondary
/// button exists, so the extra recognizer is inert; branching per platform
/// would only create a behavior matrix nobody tests.
VoidCallback? secondaryTapFor(VoidCallback? longPressAction) => longPressAction;
