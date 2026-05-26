// ============================================================
// Toast Service (minimal stub for this extract)
// ============================================================
// In the production app this drives a global ScaffoldMessenger key so
// any layer can surface a toast without holding a BuildContext. Here it
// is reduced to a debug stub so the data-layer files read naturally.
// ============================================================

import 'package:flutter/foundation.dart';

class ToastService {
  ToastService._();

  static void error(String message) {
    debugPrint('[toast:error] $message');
  }

  static void success(String message) {
    debugPrint('[toast:success] $message');
  }
}
