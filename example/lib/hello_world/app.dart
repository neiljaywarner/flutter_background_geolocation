import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ENV.dart';

JsonEncoder encoder = new JsonEncoder.withIndent("     ");

class HelloWorldApp extends StatelessWidget {
  static const String NAME = 'hello_world';

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = ThemeData();
    return new MaterialApp(
      title: 'BackgroundGeolocation Demo',
      theme: theme.copyWith(
          colorScheme: theme.colorScheme.copyWith(secondary: Colors.black),
          primaryTextTheme: Theme.of(context).primaryTextTheme.apply(
                bodyColor: Colors.black,
              )),
      home: new HelloWorldPage(),
    );
  }
}

class HelloWorldPage extends StatefulWidget {
  HelloWorldPage({Key? key}) : super(key: key);

  @override
  _HelloWorldPageState createState() => new _HelloWorldPageState();
}

class _HelloWorldPageState extends State<HelloWorldPage> {
  Future<SharedPreferences> _prefs = SharedPreferences.getInstance();

  late bool _enabled;
  late String _content;

  @override
  void initState() {
    super.initState();
    _content = "    Enable the switch to begin tracking.";
    _enabled = false;
    _content = '';
    _initPlatformState();
  }

  Future _initPlatformState() async {
    SharedPreferences prefs = await _prefs;
    String orgname = prefs.getString("orgname") ?? '';
    String username = prefs.getString("username") ?? '';

    if (orgname.isEmpty || username.isEmpty) {
      throw Exception('must have org and username');
    }
    debugPrint('orgName=$orgname;username=$username');
    try {
      await Hive.initFlutter();
    } catch (e) {
      prefs.setString('initflutterfail', 'last:${DateTime.now()}');
    }

    // Fetch a Transistor demo server Authorization token for tracker.transistorsoft.com.
    bg.TransistorAuthorizationToken token =
        await bg.TransistorAuthorizationToken.findOrCreate(orgname, username, ENV.TRACKER_HOST);

    // 1.  Listen to events (See docs for all 12 available events).
    bg.BackgroundGeolocation.onLocation(_onLocation, _onLocationError);
    bg.BackgroundGeolocation.onMotionChange(_onMotionChange);
    bg.BackgroundGeolocation.onActivityChange(_onActivityChange);
    bg.BackgroundGeolocation.onProviderChange(_onProviderChange);
    bg.BackgroundGeolocation.onConnectivityChange(_onConnectivityChange);
    bg.BackgroundGeolocation.onHttp(_onHttp);
    bg.BackgroundGeolocation.onAuthorization(_onAuthorization);

    // 2.  Configure the plugin
    bg.BackgroundGeolocation.ready(bg.Config(
            reset: true,
            debug: true,
            logLevel: bg.Config.LOG_LEVEL_VERBOSE,
            desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
            distanceFilter: 10.0,
            backgroundPermissionRationale: bg.PermissionRationale(
                title:
                    "Allow {applicationName} to access this device's location even when the app is closed or not in use.",
                message:
                    "This app collects location data to enable recording your trips to work and calculate distance-travelled.",
                positiveAction: 'Change to "{backgroundPermissionOptionLabel}"',
                negativeAction: 'Cancel'),
            url: "${ENV.TRACKER_HOST}/api/locations",
            authorization: bg.Authorization(
                // <-- demo server authenticates with JWT
                strategy: bg.Authorization.STRATEGY_JWT,
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                refreshUrl: "${ENV.TRACKER_HOST}/api/refresh_token",
                refreshPayload: {'refresh_token': '{refreshToken}'}),
            stopOnTerminate: false,
            startOnBoot: true,
            enableHeadless: true))
        .then((bg.State state) {
      print("[ready] ${state.toMap()}");
      setState(() => _enabled = state.enabled);
    }).catchError((error) {
      print('[ready] ERROR: $error');
    });
  }

  void _onClickEnable(enabled) {
    if (enabled) {
      // Reset odometer.
      bg.BackgroundGeolocation.start().then((bg.State state) {
        print('[start] success $state');
        setState(() => _enabled = state.enabled);
      }).catchError((error) {
        print('[start] ERROR: $error');
      });
    } else {
      bg.BackgroundGeolocation.stop().then((bg.State state) {
        print('[stop] success: $state');

        setState(() => _enabled = state.enabled);
      });
    }
  }

  void _onLocation(bg.Location location) {
    print('[location] - $location');

    setState(() => _content = encoder.convert(location.toMap()));
  }

  void _onLocationError(bg.LocationError error) {
    print('[location] ERROR - $error');
  }

  void _onMotionChange(bg.Location location) {
    if (location.isMoving) {
      print('[motionchange-moving] - $location');
    } else {
      print('[motionchange-stopped] - $location');
    }
  }

  Future<void> _onActivityChange(bg.ActivityChangeEvent event) async {
    // ** shaking when device locked still triggers this callback.
    print('[activitychange] - $event');
    try {
      var box = await Hive.openBox('testBox');
      String prevValue = box.get('activity', defaultValue: '?');

      String firstTime = box.get('firstTime', defaultValue: 'UNLOCKEDBOXdefaultValueFirstTime');
      print('UNLfirstTIme=$firstTime');
      if (firstTime == 'UNLOCKEDBOXdefaultValueFirstTime') {
        box.put('firstTime', DateTime.now().toString());
      }
      box.put('activity', event.toString());
      box.put('prevActivity', prevValue);
      /*
      box.watch().listen((event) {
        print('UNlockedboxevent: ${event.key}: ${event.value}');
      });

       */

      var lockedBox = await openLockedBox();
      String prevValue2 = lockedBox.get('activity', defaultValue: '?');
      lockedBox.put('activity', event.toString());
      lockedBox.put('prevActivity', prevValue2);
      /*
      lockedBox.watch().listen((event) {
        print('lockedboxevent: ${event.key}: ${event.value}');
      });

       */
      String firstTimeLocked = lockedBox.get('firstTime', defaultValue: 'LOCKEDBOXdefaultValueFirstTime');
      print('LfirstTIme=$firstTimeLocked');

      /// see https://github.com/isar/hive/issues/192
      /// Recovering corrupted box.
      if (firstTimeLocked == 'LOCKEDBOXdefaultValueFirstTime') {
        lockedBox.put('firstTime', DateTime.now().toString());
      }
      await lockedBox.close();
      await box.close();
    } catch (e) {
      print('---**-----');
      print(e.toString());
    }
  }

  Future<Box> openLockedBox() async {
    const secureStorage = FlutterSecureStorage();
    String encryptionKey = await secureStorage.read(key: 'hiveEncryptKey') ?? 'null';
    if (encryptionKey == 'null') {
      bool containsKey = await secureStorage.containsKey(key: 'hiveEncryptKey');
      print('containsKey=$containsKey');
    }
    if (encryptionKey.isEmpty) {
      final key = Hive.generateSecureKey();
      encryptionKey = base64UrlEncode(key);
      await secureStorage.write(key: 'hiveEncryptKey', value: encryptionKey);
    }
    final realKey = base64Url.decode(encryptionKey);

    return await Hive.openBox('lockedbox', encryptionCipher: HiveAesCipher(realKey));
  }

  void _onHttp(bg.HttpEvent event) async {
    print('[${bg.Event.HTTP}] - $event');
  }

  void _onAuthorization(bg.AuthorizationEvent event) async {
    print('[${bg.Event.AUTHORIZATION}] = $event');

    bg.BackgroundGeolocation.setConfig(bg.Config(url: ENV.TRACKER_HOST + '/api/locations'));
  }

  void _onProviderChange(bg.ProviderChangeEvent event) {
    print('$event');

    setState(() => _content = encoder.convert(event.toMap()));
  }

  void _onConnectivityChange(bg.ConnectivityChangeEvent event) {
    print('$event');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('iOS Demo BG Geo'),
            foregroundColor: Colors.black,
            actions: <Widget>[Switch(value: _enabled, onChanged: _onClickEnable)],
            backgroundColor: Colors.amberAccent),
        body: SingleChildScrollView(child: Text('$_content')),
      );
}
