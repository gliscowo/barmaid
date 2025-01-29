import 'package:endec/endec.dart';
import 'package:endec/endec_annotation.dart';
import 'package:endec_json/endec_json.dart';

part 'types.g.dart';

Endec<Map<String, dynamic>> _jsonObjectEndec() => jsonEndec.xmap(
      (self) => self as Map<String, dynamic>,
      (other) => other,
    );

@GenerateStructEndec()
class PackageIndexEntry {
  static final endec = _$PackageIndexEntryEndec;

  final String uuid;
  final String hash;

  @EndecField(endec: _jsonObjectEndec)
  final Map<String, dynamic> pubspec;

  PackageIndexEntry(this.uuid, this.hash, this.pubspec);
}

@GenerateStructEndec()
class TokenProperties {
  static final endec = _$TokenPropertiesEndec;

  final String owner;
  final Set<String> authorizedPackages;

  TokenProperties(this.owner, this.authorizedPackages);

  bool isAuthorized(String package) => authorizedPackages.contains('*') || authorizedPackages.contains(package);
}
