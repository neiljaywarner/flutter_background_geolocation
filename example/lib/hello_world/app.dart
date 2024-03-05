import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ENV.dart';

JsonEncoder encoder = new JsonEncoder.withIndent("     ");

AppLifecycleState? appState;

const String hiveKeyIsReadable = 'HiveIsReadableKeyName';
const String sharedPrefsKeyInitTime = 'SharedPrefsInitTimeKeyName';

Logger log = Logger(printer: PrettyPrinter(printTime: true));
const secureStorage = FlutterSecureStorage();

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

  Future<void> _onClickEnable(enabled) async {
    if (enabled) {
      await openAndWriteAndClose('LastStarted', DateTime.now().toString());
      bg.BackgroundGeolocation.start().then((bg.State state) {
        log.d('[start] success $state');
        setState(() => _enabled = state.enabled);
      }).catchError((error) {
        log.e('[start] ERROR: $error');
      });
    } else {
      await openAndWriteAndClose('LastStopped', DateTime.now().toString());
      bg.BackgroundGeolocation.stop().then((bg.State state) {
        log.d('[stop] success: $state');

        setState(() => _enabled = state.enabled);
      });
    }
  }

  Future<void> _onLocation(bg.Location location) async {
    log.d('[onLocation] - $location;');
    try {
      var lockedBox = await openLockedBox();
      lockedBox.put('locationTime', DateTime.now().toString());
      var box = await Hive.openBox('testBox');

      box.put('locationTime', DateTime.now().toString());
      await lockedBox.compact();
      await lockedBox.close();
      setState(() => _content = encoder.convert(location.toMap()));
    } catch (e) {
      log.e('---**--$e---');
    }
  }

  void _onLocationError(bg.LocationError error) => log.e('[location] ERROR - $error');

  void _onMotionChange(bg.Location location) => log.d('onMotionChange: ${location.isMoving}');

  Future<void> _onActivityChange(bg.ActivityChangeEvent event) async {
    // ** shaking when device locked still triggers this callback.
    log.d('[activitychange] - $event');
    try {
      var box = await Hive.openBox('testBox');
      await box.put('activityTime', DateTime.now().toString()); // so it for surer has value
      bool canReadSecureStorage = await isSecureStorageReadable();
      log.d('*** canReadSecureStorage=$canReadSecureStorage');
      var lockedBox = await openLockedBox();
      box.put('activityTime', DateTime.now().toString());
      lockedBox.put('activityTime', DateTime.now().toString());

      await lockedBox.compact();
      await lockedBox.close();
      await box.compact();
      await box.close();
    } catch (e) {
      log.e('---**--$e---');
    }
  }

  Future<void> openAndWriteAndClose(String key, String value) async {
    try {
      var lockedBox = await openLockedBox();
      String lastValue = lockedBox.get(key, defaultValue: '');
      log.d('key/lastValue=$key/$lastValue');
      await lockedBox.put(key, value);
      await lockedBox.compact();
      await lockedBox.close();
    } catch (e) {
      log.e('---OAWAC--$e---');
    }
  }

  Future<bool> isReadWriteOk() async {
    String nowString = DateTime.now().toString();
    await secureStorage.write(key: hiveKeyIsReadable, value: nowString);
    String? nowStringFromSecureStorage = await secureStorage.read(key: hiveKeyIsReadable);
    if (nowString == nowStringFromSecureStorage) {
      return true;
    } else {
      bool containsKey = await secureStorage.containsKey(key: hiveKeyIsReadable);
      log.e('containsIsReadableKey=$containsKey');
      return false;
    }
  }

  Future<bool> isSecureStorageReadable() async {
    bool isWriteReadOKPassed = await isReadWriteOk();

    return isWriteReadOKPassed;
  }

  Future<Box> openLockedBox() async {
    bool canReadSecureStorage = await isSecureStorageReadable();
    if (!canReadSecureStorage) {
      log.e('cannot read secure storage, return null for box and nothing breaks');
      //return null;
      //throw Exception('do not open box if storage is not readable');
    }
    String encryptionKey = await secureStorage.read(key: 'hiveEncryptKey') ?? 'null';
    if (encryptionKey == 'null') {
      bool containsKey = await secureStorage.containsKey(key: 'hiveEncryptKey');
      log.e('containsKey=$containsKey; canReadSecureStorage=$canReadSecureStorage ');
    }
    if (encryptionKey == 'null') {
      final key = Hive.generateSecureKey();
      encryptionKey = base64UrlEncode(key);
      await secureStorage.write(key: 'hiveEncryptKey', value: encryptionKey);
    }
    final realKey = base64Url.decode(encryptionKey);

    return await Hive.openBox('lockedbox', encryptionCipher: HiveAesCipher(realKey));
  }

  void _onAuthorization(bg.AuthorizationEvent event) async =>
      bg.BackgroundGeolocation.setConfig(bg.Config(url: ENV.TRACKER_HOST + '/api/locations'));

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
