import 'package:flutter/services.dart' show appBuildName, appBuildNumber;

const clientVersion = appBuildName ?? '0.1.0';
const clientBuildNumber = appBuildNumber ?? '261031010';
