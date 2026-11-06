import 'package:flutter/services.dart' show appBuildName, appBuildNumber;

const clientVersion = appBuildName ?? '0.1.1';
const clientBuildNumber = appBuildNumber ?? '261031019';
