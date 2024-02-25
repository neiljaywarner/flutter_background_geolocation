import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/transistor_auth.dart';
import 'hello_world/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  /// Application selection:  Select the app to boot:
  /// - AdvancedApp
  /// - HelloWorldAp
  /// - HomeApp
  ///
  SharedPreferences.getInstance().then((SharedPreferences prefs) {
    prefs.setString("orgname", 'njw');
    prefs.setString("username", 'njw');
  });
  // or AdvancedApp()
  runApp(HelloWorldApp());
  TransistorAuth.registerErrorHandler();
}
