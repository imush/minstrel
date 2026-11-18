import 'package:flutter/material.dart';

/// Shows a menu built by [builder] in a bottom sheet that is as tall as it
/// needs to be, up to most of the screen, and scrolls past that.
///
/// Left to itself a bottom sheet stops at 9/16 of the screen and cuts a
/// longer menu off at the bottom, which put the last row in Android's
/// gesture strip. Let it grow instead, and a phone held sideways in a car
/// mount gets a menu that fills the screen: nothing above it to tap, and
/// dragging it down only scrolls the list. So it stops short of the top,
/// and pulling down past the start of the list closes it.
Future<T?> showMenuSheet<T>(BuildContext context, {required WidgetBuilder builder}) =>
    showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      // 640 wide is Material 3's own limit for a sheet, kept.
      constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (context) => _PullToClose(
        child: SafeArea(child: SingleChildScrollView(child: builder(context))),
      ),
    );

class _PullToClose extends StatefulWidget {
  final Widget child;
  const _PullToClose({required this.child});

  @override
  State<_PullToClose> createState() => _PullToCloseState();
}

class _PullToCloseState extends State<_PullToClose> {
  /// How far past the top the list has been pulled in this drag.
  double _pulled = 0;
  bool _closing = false;

  static const _enough = 64.0;

  bool _onScroll(ScrollNotification n) {
    switch (n) {
      // Android's clamping list stops at the top and reports the rest.
      case OverscrollNotification(:final overscroll, :final dragDetails)
          when dragDetails != null && overscroll < 0:
        _pulled -= overscroll;
      // iOS's bouncing list goes past the top instead.
      case ScrollUpdateNotification(:final metrics, :final dragDetails) when dragDetails != null:
        _pulled = metrics.minScrollExtent - metrics.pixels;
      case ScrollEndNotification():
        _pulled = 0;
      default:
    }
    if (_pulled > _enough && !_closing) {
      _closing = true;
      Navigator.of(context).maybePop();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child);
}
