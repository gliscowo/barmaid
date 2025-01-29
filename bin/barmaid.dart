import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

final authPattern = RegExp('Bearer (.*)');
const fileDispositionHeader = 'form-data; name="file"; filename="package.tar.gz"';
const pubContentType = {
  HttpHeaders.contentTypeHeader: 'application/vnd.pub.v2+json',
};

const repoDir = 'package_repo';

typedef Upload = ({
  Pubspec parsedPubspec,
  Map<String, dynamic> pubspecJson,
  List<int> archiveBytes,
  Timer expirationTimer,
});

final uploadCache = <String, Upload>{};

Map<String, dynamic> analyzeUpload(List<int> fileBytes) {
  final archive = TarDecoder().decodeBytes(gzip.decode(fileBytes));

  final pubspecFile = archive.findFile('pubspec.yaml');
  if (pubspecFile == null) {
    throw AnalysisException('missing_pubspec', 'no pubspec in uploaded package');
  }

  return (loadYaml(utf8.decode(pubspecFile.readBytes()!)) as YamlMap).cast();
}

final packageIndexCache = <String, List<Map<String, dynamic>>>{};

Future<List<Map<String, dynamic>>?> loadPackageIndex(String package, {bool allowEmpty = false}) async {
  if (packageIndexCache.containsKey(package)) {
    return packageIndexCache[package];
  }

  final packageIndexFile = File(join(repoDir, package, 'index.json'));
  final indexExists = await packageIndexFile.exists();

  if (!allowEmpty && !indexExists) {
    return null;
  }

  return indexExists ? (jsonDecode(await packageIndexFile.readAsString()) as List<dynamic>).cast() : [];
}

Future<void> savePackageIndex(String package, List<Map<String, dynamic>> index) async {
  final packageIndexFile = File(join(repoDir, package, 'index.json'));
  await packageIndexFile.create(recursive: true);
  await packageIndexFile.writeAsString(const JsonEncoder.withIndent('  ').convert(index));

  packageIndexCache[package] = index;
}

Future<void> main(List<String> args) async {
  final app = Router();
  final baseUrl = args.first;

  final tokens = (jsonDecode(await File('tokens.json').readAsString()) as Map<String, dynamic>).map(
    (key, value) => MapEntry(key, Set<String>.from(value['authorized_packages'])),
  );

  await Directory(repoDir).create();

  Response errorResponse(
    String code,
    String message, {
    int statusCode = HttpStatus.badRequest,
  }) =>
      Response(
        statusCode,
        headers: pubContentType,
        body: jsonEncode({
          'error': {'code': code, 'message': message}
        }),
      );

  String? getToken(Request request) {
    final authHeader = request.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) return null;

    return authPattern.firstMatch(authHeader)?[1];
  }

  Response? checkAuth(Request request, [String? package]) {
    final token = getToken(request);
    if (token == null) {
      return Response.unauthorized(
        null,
        headers: {HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="pub", message="no token provided"'},
      );
    }

    if (!tokens.containsKey(token)) {
      return Response.unauthorized(
        null,
        headers: {HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="pub", message="invalid token"'},
      );
    }

    if (package == null) {
      return null;
    }

    final packagesForToken = tokens[token]!;
    if (packagesForToken.contains('*') || packagesForToken.contains(package)) return null;

    return Response.forbidden(
      null,
      headers: {
        HttpHeaders.wwwAuthenticateHeader: 'Bearer realm="pub", message="insufficient authorization for package"'
      },
    );
  }

  app.get('/api/packages/versions/new', (Request request) {
    if (checkAuth(request) case var response?) {
      return response;
    }

    return Response.ok(
      jsonEncode({'url': '$baseUrl/api/upload/content', 'fields': {}}),
      headers: pubContentType,
    );
  });

  app.post('/api/upload/content', (Request request) async {
    final archiveBytes = await request
        .multipart()!
        .parts
        .cast<Multipart>()
        .singleWhere((element) => element.headers[HttpHeaders.contentDisposition] == fileDispositionHeader)
        .then((value) => value.expand((e) => e).toList());

    Map<String, dynamic> archivePubspec;
    try {
      archivePubspec = analyzeUpload(archiveBytes);
    } on AnalysisException catch (ex) {
      return errorResponse(ex.errorCode, ex.message);
    }

    final packageName = archivePubspec['name'];
    if (checkAuth(request, packageName) case var response?) {
      return response;
    }

    final uploadUuid = const Uuid().v4();
    uploadCache[uploadUuid] = (
      parsedPubspec: Pubspec.fromJson(archivePubspec),
      pubspecJson: archivePubspec,
      archiveBytes: archiveBytes,
      expirationTimer: Timer(Duration(minutes: 1), () => uploadCache.remove(uploadUuid)),
    );

    return Response(
      HttpStatus.noContent,
      headers: {HttpHeaders.locationHeader: '$baseUrl/api/upload/finalize/$packageName/$uploadUuid'},
    );
  });

  app.get('/api/upload/finalize/<package>/<upload-uuid>', (Request request, String package, String uploadUuid) async {
    if (checkAuth(request, package) case var response?) {
      return response;
    }

    final (:parsedPubspec, :pubspecJson, :archiveBytes, :expirationTimer) = uploadCache[uploadUuid]!;
    expirationTimer.cancel();

    final packageIndex = await loadPackageIndex(parsedPubspec.name, allowEmpty: true);
    packageIndex!;

    if (packageIndex.any((element) => element['pubspec']['version'] == parsedPubspec.version.toString())) {
      return errorResponse('duplicate_version', 'version ${parsedPubspec.version} already exists');
    }

    final versionUuid = const Uuid().v4();
    packageIndex.add({
      'uuid': versionUuid,
      'hash': sha256.convert(archiveBytes).toString(),
      'pubspec': pubspecJson,
    });

    await savePackageIndex(parsedPubspec.name, packageIndex);

    final archiveFile = File(join(repoDir, parsedPubspec.name, '$versionUuid.tar.gz'));
    await archiveFile.writeAsBytes(archiveBytes);

    return Response.ok(
      headers: pubContentType,
      jsonEncode({
        'success': {'message': ':brombeere:'}
      }),
    );
  });

  app.get('/api/packages/<package-name>', (Request request, String packageName) async {
    final packageIndex = await loadPackageIndex(packageName);
    if (packageIndex == null) {
      return errorResponse('unknown_package', 'unknown package', statusCode: HttpStatus.notFound);
    }

    Map<String, dynamic> encodeVersion(Map<String, dynamic> indexEntry) => {
          'version': indexEntry['pubspec']['version'],
          'archive_url': '$baseUrl/api/packages/$packageName/archive/${indexEntry['uuid']}.tar.gz',
          'archive_sha256': indexEntry['hash'],
          'pubspec': indexEntry['pubspec']
        };

    return Response.ok(
      headers: pubContentType,
      jsonEncode({
        'name': packageName,
        'latest': {
          'version': encodeVersion(packageIndex.last),
        },
        'versions': packageIndex.map(encodeVersion).toList()
      }),
    );
  });

  app.get(
    '/api/packages/<package-name>/archive/<version-uuid>.tar.gz',
    (Request request, String packageName, String versionUuid) async {
      final packageIndex = await loadPackageIndex(packageName);
      if (packageIndex == null || !packageIndex.any((element) => element['uuid'] == versionUuid)) {
        return errorResponse('unkown_version', 'unknown version', statusCode: HttpStatus.notFound);
      }

      final archivesDirPath = join(repoDir, packageName);
      final archiveFile = File(join(archivesDirPath, '$versionUuid.tar.gz'));

      if (!isWithin(archivesDirPath, archiveFile.path) || !await archiveFile.exists()) {
        return errorResponse('unkown_version', 'unknown version', statusCode: HttpStatus.notFound);
      }

      return Response.ok(
        archiveFile.openRead(),
        headers: {HttpHeaders.contentTypeHeader: ContentType.binary.toString()},
      );
    },
  );

  await serve(app.call, 'localhost', 3675);
  print('serving pub packages on localhost:3675');
}

class AnalysisException implements Exception {
  final String message, errorCode;
  AnalysisException(this.message, this.errorCode);
}
