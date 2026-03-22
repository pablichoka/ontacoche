double? computeKeyboardScrollOffset({
  required double fieldGlobalY,
  required double fieldHeight,
  required double screenHeight,
  required double keyboardHeight,
  required double currentScrollOffset,
  double topInset = 0,
  double bottomInset = 0,
  double extraPadding = 16,
}) {
  // Area visible above the keyboard.
  final visibleHeight = screenHeight - keyboardHeight - topInset - bottomInset;
  final fieldBottom = fieldGlobalY + fieldHeight;

  // Desired bottom position for the field (with extra padding).
  final desiredBottom = fieldBottom + extraPadding;

  if (desiredBottom <= visibleHeight) {
    return null;
  }

  final delta = desiredBottom - visibleHeight;
  return currentScrollOffset + delta;
}
