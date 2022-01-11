// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.


import 'dart:async';

import 'package:flutter/foundation.dart';

import 'arena.dart';
import 'binding.dart';
import 'constants.dart';
import 'drag.dart';
import 'drag_details.dart';
import 'events.dart';
import 'gesture_settings.dart';
import 'recognizer.dart';
import 'velocity_tracker.dart';

/// Signature for when [MultiDragGestureRecognizer] recognizes the start of a drag gesture.
typedef GestureMultiDragStartCallback = Drag? Function(PointerDownEvent startEvent);

/// Per-pointer state for a [MultiDragGestureRecognizer].
///
/// A [MultiDragGestureRecognizer] tracks each pointer separately. The state for
/// each pointer is a subclass of [MultiDragPointerState].
abstract class MultiDragPointerState {
  /// Creates per-pointer state for a [MultiDragGestureRecognizer].
  ///
  /// The [initialPosition] argument must not be null.
  MultiDragPointerState(this.initialPointerEvent, this.gestureSettings)
      : assert(initialPointerEvent != null),
      _velocityTracker = VelocityTracker.withKind(initialPointerEvent.kind);

  /// Device specific gesture configuration that should be preferred over
  /// framework constants.
  ///
  /// These settings are commonly retrieved from a [MediaQuery].
  final DeviceGestureSettings? gestureSettings;

  /// The [PointerEvent] performing the multi-drag gesture.
  final PointerDownEvent initialPointerEvent;
  
  /// The global coordinates of the pointer when the pointer contacted the screen.
  Offset get initialPosition => initialPointerEvent.position;

  final VelocityTracker _velocityTracker;

  /// The kind of pointer performing the multi-drag gesture.
  ///
  /// Used by subclasses to determine the appropriate hit slop, for example.
  PointerDeviceKind get kind => initialPointerEvent.kind;

  Drag? _client;

  /// The offset of the pointer from the last position that was reported to the client.
  ///
  /// After the pointer contacts the screen, the pointer might move some
  /// distance before this movement will be recognized as a drag. This field
  /// accumulates that movement so that we can report it to the client after
  /// the drag starts.
  Offset? get pendingDelta => _pendingDelta;
  Offset? _pendingDelta = Offset.zero;

  Duration? _lastPendingEventTimestamp;

  GestureArenaEntry? _arenaEntry;
  void _setArenaEntry(GestureArenaEntry entry) {
    assert(_arenaEntry == null);
    assert(pendingDelta != null);
    assert(_client == null);
    _arenaEntry = entry;
  }

  /// Resolve this pointer's entry in the [GestureArenaManager] with the given disposition.
  @protected
  @mustCallSuper
  void resolve(GestureDisposition disposition) {
    _arenaEntry!.resolve(disposition);
  }

  void _move(PointerMoveEvent event) {
    assert(_arenaEntry != null);
    if (!event.synthesized)
      _velocityTracker.addPosition(event.timeStamp, event.position);
    if (_client != null) {
      assert(pendingDelta == null);
      // Call client last to avoid reentrancy.
      _client!.update(DragUpdateDetails(
        event: event,
        sourceTimeStamp: event.timeStamp,
        delta: event.delta,
        globalPosition: event.position,
      ));
    } else {
      assert(pendingDelta != null);
      _pendingDelta = _pendingDelta! + event.delta;
      _lastPendingEventTimestamp = event.timeStamp;
      checkForResolutionAfterMove();
    }
  }

  /// Override this to call resolve() if the drag should be accepted or rejected.
  /// This is called when a pointer movement is received, but only if the gesture
  /// has not yet been resolved.
  @protected
  void checkForResolutionAfterMove() { }

  /// Called when the gesture was accepted.
  ///
  /// Either immediately or at some future point before the gesture is disposed,
  /// call starter(), passing it initialPosition, to start the drag.
  @protected
  void accepted(GestureMultiDragStartCallback starter);

  /// Called when the gesture was rejected.
  ///
  /// The [dispose] method will be called immediately following this.
  @protected
  @mustCallSuper
  void rejected() {
    assert(_arenaEntry != null);
    assert(_client == null);
    assert(pendingDelta != null);
    _pendingDelta = null;
    _lastPendingEventTimestamp = null;
    _arenaEntry = null;
  }

  void _startDrag(Drag client) {
    assert(_arenaEntry != null);
    assert(_client == null);
    assert(client != null);
    assert(pendingDelta != null);
    _client = client;
    assert(initialPointerEvent is PointerDownEvent);
    _pendingDelta = null;
    _lastPendingEventTimestamp = null;
    // Call client last to avoid reentrancy.
    _client!.start(DragStartDetails.fromPointerDownEvent(initialPointerEvent));
  }

  void _up(PointerUpEvent event) {
    assert(_arenaEntry != null);
    if (_client != null) {
      assert(pendingDelta == null);
      final DragEndDetails details = DragEndDetails(
        event: event,
        velocity: _velocityTracker.getVelocity(),
      );
      final Drag client = _client!;
      _client = null;
      // Call client last to avoid reentrancy.
      client.end(details);
    } else {
      assert(pendingDelta != null);
      _pendingDelta = null;
      _lastPendingEventTimestamp = null;
    }
  }

  void _cancel() {
    assert(_arenaEntry != null);
    if (_client != null) {
      assert(pendingDelta == null);
      final Drag client = _client!;
      _client = null;
      // Call client last to avoid reentrancy.
      client.cancel();
    } else {
      assert(pendingDelta != null);
      _pendingDelta = null;
      _lastPendingEventTimestamp = null;
    }
  }

  /// Releases any resources used by the object.
  @protected
  @mustCallSuper
  void dispose() {
    _arenaEntry?.resolve(GestureDisposition.rejected);
    _arenaEntry = null;
    assert(() {
      _pendingDelta = null;
      return true;
    }());
  }
}

/// Recognizes movement on a per-pointer basis.
///
/// In contrast to [DragGestureRecognizer], [MultiDragGestureRecognizer] watches
/// each pointer separately, which means multiple drags can be recognized
/// concurrently if multiple pointers are in contact with the screen.
///
/// [MultiDragGestureRecognizer] is not intended to be used directly. Instead,
/// consider using one of its subclasses to recognize specific types for drag
/// gestures.
///
/// See also:
///
///  * [ImmediateMultiDragGestureRecognizer], the most straight-forward variant
///    of multi-pointer drag gesture recognizer.
///  * [HorizontalMultiDragGestureRecognizer], which only recognizes drags that
///    start horizontally.
///  * [VerticalMultiDragGestureRecognizer], which only recognizes drags that
///    start vertically.
///  * [DelayedMultiDragGestureRecognizer], which only recognizes drags that
///    start after a long-press gesture.
abstract class MultiDragGestureRecognizer extends GestureRecognizer {
  /// Initialize the object.
  ///
  /// {@macro flutter.gestures.GestureRecognizer.supportedDevices}
  MultiDragGestureRecognizer({
    required Object? debugOwner,
    @Deprecated(
      'Migrate to supportedDevices. '
      'This feature was deprecated after v2.3.0-1.0.pre.',
    )
    PointerDeviceKind? kind,
    Set<PointerDeviceKind>? supportedDevices,
  }) : super(
         debugOwner: debugOwner,
         kind: kind,
         supportedDevices: supportedDevices,
       );

  /// Called when this class recognizes the start of a drag gesture.
  ///
  /// The remaining notifications for this drag gesture are delivered to the
  /// [Drag] object returned by this callback.
  GestureMultiDragStartCallback? onStart;

  Map<int, MultiDragPointerState>? _pointers = <int, MultiDragPointerState>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    print('Add Allowed Pointer Function');
    assert(_pointers != null);
    assert(event.pointer != null);
    assert(event.position != null);
    assert(!_pointers!.containsKey(event.pointer));
    final MultiDragPointerState state = createNewPointerState(event);
    _pointers![event.pointer] = state;
    GestureBinding.instance!.pointerRouter.addRoute(event.pointer, _handleEvent);
    state._setArenaEntry(GestureBinding.instance!.gestureArena.add(event.pointer, this));
  }

  /// Subclasses should override this method to create per-pointer state
  /// objects to track the pointer associated with the given event.
  @protected
  @factory
  MultiDragPointerState createNewPointerState(PointerDownEvent event);

  void _handleEvent(PointerEvent event) {
    assert(_pointers != null);
    assert(event.pointer != null);
    assert(event.timeStamp != null);
    assert(event.position != null);
    assert(_pointers!.containsKey(event.pointer));
    final MultiDragPointerState state = _pointers![event.pointer]!;
    if (event is PointerMoveEvent) {
      state._move(event);
      // We might be disposed here.
    } else if (event is PointerUpEvent) {
      assert(event.delta == Offset.zero);
      state._up(event);
      // We might be disposed here.
      _removeState(event.pointer);
    } else if (event is PointerCancelEvent) {
      assert(event.delta == Offset.zero);
      state._cancel();
      // We might be disposed here.
      _removeState(event.pointer);
    } else if (event is! PointerDownEvent) {
      // we get the PointerDownEvent that resulted in our addPointer getting called since we
      // add ourselves to the pointer router then (before the pointer router has heard of
      // the event).
      assert(false);
    }
  }

  @override
  void acceptGesture(int pointer) {
    assert(_pointers != null);
    final MultiDragPointerState? state = _pointers![pointer];
    if (state == null)
      return; // We might already have canceled this drag if the up comes before the accept.
    // todo: I'm confused, if we map the event's pointer to a MultiDragPointerState, then
    state.accepted((PointerDownEvent initialEvent) => _startDrag(initialEvent));
  }

  Drag? _startDrag(PointerDownEvent initialEvent) {
    assert(_pointers != null);
    final MultiDragPointerState state = _pointers![initialEvent.pointer]!;
    assert(state != null);
    assert(state._pendingDelta != null);
    Drag? drag;
    if (onStart != null)
      drag = invokeCallback<Drag?>('onStart', () => onStart!(initialEvent));
    if (drag != null) {
      state._startDrag(drag);
    } else {
      _removeState(initialEvent.pointer);
    }
    return drag;
  }

  @override
  void rejectGesture(int pointer) {
    assert(_pointers != null);
    if (_pointers!.containsKey(pointer)) {
      final MultiDragPointerState state = _pointers![pointer]!;
      assert(state != null);
      state.rejected();
      _removeState(pointer);
    } // else we already preemptively forgot about it (e.g. we got an up event)
  }

  void _removeState(int pointer) {
    if (_pointers == null) {
      // We've already been disposed. It's harmless to skip removing the state
      // for the given pointer because dispose() has already removed it.
      return;
    }
    assert(_pointers!.containsKey(pointer));
    GestureBinding.instance!.pointerRouter.removeRoute(pointer, _handleEvent);
    _pointers!.remove(pointer)!.dispose();
  }

  @override
  void dispose() {
    _pointers!.keys.toList().forEach(_removeState);
    assert(_pointers!.isEmpty);
    _pointers = null;
    super.dispose();
  }
}

class _ImmediatePointerState extends MultiDragPointerState {
  _ImmediatePointerState(PointerDownEvent event, DeviceGestureSettings? deviceGestureSettings) : super(event, deviceGestureSettings);

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta!.distance > computeHitSlop(kind, gestureSettings))
      resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPointerEvent);
  }
}

/// Recognizes movement both horizontally and vertically on a per-pointer basis.
///
/// In contrast to [PanGestureRecognizer], [ImmediateMultiDragGestureRecognizer]
/// watches each pointer separately, which means multiple drags can be
/// recognized concurrently if multiple pointers are in contact with the screen.
///
/// See also:
///
///  * [PanGestureRecognizer], which recognizes only one drag gesture at a time,
///    regardless of how many fingers are involved.
///  * [HorizontalMultiDragGestureRecognizer], which only recognizes drags that
///    start horizontally.
///  * [VerticalMultiDragGestureRecognizer], which only recognizes drags that
///    start vertically.
///  * [DelayedMultiDragGestureRecognizer], which only recognizes drags that
///    start after a long-press gesture.
class ImmediateMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  /// Create a gesture recognizer for tracking multiple pointers at once.
  ///
  /// {@macro flutter.gestures.GestureRecognizer.supportedDevices}
  ImmediateMultiDragGestureRecognizer({
    Object? debugOwner,
    @Deprecated(
      'Migrate to supportedDevices. '
      'This feature was deprecated after v2.3.0-1.0.pre.',
    )
    PointerDeviceKind? kind,
    Set<PointerDeviceKind>? supportedDevices,
  }) : super(
         debugOwner: debugOwner,
         kind: kind,
         supportedDevices: supportedDevices,
       );

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _ImmediatePointerState(event, gestureSettings);
  }

  @override
  String get debugDescription => 'multidrag';
}


class _HorizontalPointerState extends MultiDragPointerState {
  _HorizontalPointerState(PointerDownEvent event, DeviceGestureSettings? deviceGestureSettings): super(event, deviceGestureSettings);

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta!.dx.abs() > computeHitSlop(kind, gestureSettings))
      resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPointerEvent);
  }
}

/// Recognizes movement in the horizontal direction on a per-pointer basis.
///
/// In contrast to [HorizontalDragGestureRecognizer],
/// [HorizontalMultiDragGestureRecognizer] watches each pointer separately,
/// which means multiple drags can be recognized concurrently if multiple
/// pointers are in contact with the screen.
///
/// See also:
///
///  * [HorizontalDragGestureRecognizer], a gesture recognizer that just
///    looks at horizontal movement.
///  * [ImmediateMultiDragGestureRecognizer], a similar recognizer, but without
///    the limitation that the drag must start horizontally.
///  * [VerticalMultiDragGestureRecognizer], which only recognizes drags that
///    start vertically.
class HorizontalMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  /// Create a gesture recognizer for tracking multiple pointers at once
  /// but only if they first move horizontally.
  ///
  /// {@macro flutter.gestures.GestureRecognizer.supportedDevices}
  HorizontalMultiDragGestureRecognizer({
    Object? debugOwner,
    @Deprecated(
      'Migrate to supportedDevices. '
      'This feature was deprecated after v2.3.0-1.0.pre.',
    )
    PointerDeviceKind? kind,
    Set<PointerDeviceKind>? supportedDevices,
  }) : super(
         debugOwner: debugOwner,
         kind: kind,
         supportedDevices: supportedDevices,
       );

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _HorizontalPointerState(event, gestureSettings);
  }

  @override
  String get debugDescription => 'horizontal multidrag';
}


class _VerticalPointerState extends MultiDragPointerState {
  _VerticalPointerState(PointerDownEvent event, DeviceGestureSettings? deviceGestureSettings): super(event, deviceGestureSettings);

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta!.dy.abs() > computeHitSlop(kind, gestureSettings))
      resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPointerEvent);
  }
}

/// Recognizes movement in the vertical direction on a per-pointer basis.
///
/// In contrast to [VerticalDragGestureRecognizer],
/// [VerticalMultiDragGestureRecognizer] watches each pointer separately,
/// which means multiple drags can be recognized concurrently if multiple
/// pointers are in contact with the screen.
///
/// See also:
///
///  * [VerticalDragGestureRecognizer], a gesture recognizer that just
///    looks at vertical movement.
///  * [ImmediateMultiDragGestureRecognizer], a similar recognizer, but without
///    the limitation that the drag must start vertically.
///  * [HorizontalMultiDragGestureRecognizer], which only recognizes drags that
///    start horizontally.
class VerticalMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  /// Create a gesture recognizer for tracking multiple pointers at once
  /// but only if they first move vertically.
  ///
  /// {@macro flutter.gestures.GestureRecognizer.supportedDevices}
  VerticalMultiDragGestureRecognizer({
    Object? debugOwner,
    @Deprecated(
      'Migrate to supportedDevices. '
      'This feature was deprecated after v2.3.0-1.0.pre.',
    )
    PointerDeviceKind? kind,
    Set<PointerDeviceKind>? supportedDevices,
  }) : super(
         debugOwner: debugOwner,
         kind: kind,
         supportedDevices: supportedDevices,
       );

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _VerticalPointerState(event, gestureSettings);
  }

  @override
  String get debugDescription => 'vertical multidrag';
}

class _DelayedPointerState extends MultiDragPointerState {
  _DelayedPointerState(PointerDownEvent event, Duration delay, DeviceGestureSettings? deviceGestureSettings)
      : assert(delay != null),
        super(event, deviceGestureSettings) {
    _timer = Timer(delay, _delayPassed);
  }

  Timer? _timer;
  GestureMultiDragStartCallback? _starter;

  void _delayPassed() {
    assert(_timer != null);
    assert(pendingDelta != null);
    assert(pendingDelta!.distance <= computeHitSlop(kind, gestureSettings));
    _timer = null;
    if (_starter != null) {
      _starter!(initialPointerEvent);
      _starter = null;
    } else {
      resolve(GestureDisposition.accepted);
    }
    assert(_starter == null);
  }

  void _ensureTimerStopped() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    assert(_starter == null);
    if (_timer == null)
      starter(initialPointerEvent);
    else
      _starter = starter;
  }

  @override
  void checkForResolutionAfterMove() {
    if (_timer == null) {
      // If we've been accepted by the gesture arena but the pointer moves too
      // much before the timer fires, we end up a state where the timer is
      // stopped but we keep getting calls to this function because we never
      // actually started the drag. In this case, _starter will be non-null
      // because we're essentially waiting forever to start the drag.
      assert(_starter != null);
      return;
    }
    assert(pendingDelta != null);
    if (pendingDelta!.distance > computeHitSlop(kind, gestureSettings)) {
      resolve(GestureDisposition.rejected);
      _ensureTimerStopped();
    }
  }

  @override
  void dispose() {
    _ensureTimerStopped();
    super.dispose();
  }
}

/// Recognizes movement both horizontally and vertically on a per-pointer basis
/// after a delay.
///
/// In contrast to [ImmediateMultiDragGestureRecognizer],
/// [DelayedMultiDragGestureRecognizer] waits for a [delay] before recognizing
/// the drag. If the pointer moves more than [kTouchSlop] before the delay
/// expires, the gesture is not recognized.
///
/// In contrast to [PanGestureRecognizer], [DelayedMultiDragGestureRecognizer]
/// watches each pointer separately, which means multiple drags can be
/// recognized concurrently if multiple pointers are in contact with the screen.
///
/// See also:
///
///  * [ImmediateMultiDragGestureRecognizer], a similar recognizer but without
///    the delay.
///  * [PanGestureRecognizer], which recognizes only one drag gesture at a time,
///    regardless of how many fingers are involved.
class DelayedMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  /// Creates a drag recognizer that works on a per-pointer basis after a delay.
  ///
  /// In order for a drag to be recognized by this recognizer, the pointer must
  /// remain in the same place for [delay] (up to [kTouchSlop]). The [delay]
  /// defaults to [kLongPressTimeout] to match [LongPressGestureRecognizer] but
  /// can be changed for specific behaviors.
  ///
  /// {@macro flutter.gestures.GestureRecognizer.supportedDevices}
  DelayedMultiDragGestureRecognizer({
    this.delay = kLongPressTimeout,
    Object? debugOwner,
    @Deprecated(
      'Migrate to supportedDevices. '
      'This feature was deprecated after v2.3.0-1.0.pre.',
    )
    PointerDeviceKind? kind,
    Set<PointerDeviceKind>? supportedDevices,
  }) : assert(delay != null),
       super(
         debugOwner: debugOwner,
         kind: kind,
         supportedDevices: supportedDevices,
       );

  /// The amount of time the pointer must remain in the same place for the drag
  /// to be recognized.
  final Duration delay;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _DelayedPointerState(event, delay, gestureSettings);
  }

  @override
  String get debugDescription => 'long multidrag';
}
