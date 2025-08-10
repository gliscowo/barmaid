import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:barmaid/auth.dart';
import 'package:barmaid/types.dart';
import 'package:crypto/crypto.dart';
import 'package:endec_json/endec_json.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

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

  return jsonDecode(jsonEncode((loadYaml(utf8.decode(pubspecFile.readBytes()!)) as YamlMap).cast<String, dynamic>()));
}

// ---

final packageIndexCache = <String, List<PackageIndexEntry>>{};
final packageIndexEndec = PackageIndexEntry.endec.listOf();
const jsonEncoder = JsonEncoder.withIndent('  ');

Future<List<PackageIndexEntry>?> loadPackageIndex(String package, {bool allowEmpty = false}) async {
  if (packageIndexCache.containsKey(package)) {
    return packageIndexCache[package];
  }

  final packageIndexFile = File(join(repoDir, package, 'index.json'));
  final indexExists = await packageIndexFile.exists();

  if (!allowEmpty && !indexExists) {
    return null;
  }

  return indexExists ? fromJson(packageIndexEndec, jsonDecode(await packageIndexFile.readAsString())) : [];
}

Future<void> savePackageIndex(String package, List<PackageIndexEntry> index) async {
  final packageIndexFile = File(join(repoDir, package, 'index.json'));
  await packageIndexFile.create(recursive: true);
  await packageIndexFile.writeAsString(jsonEncoder.convert(toJson(packageIndexEndec, index)));

  packageIndexCache[package] = index;
}

// ---

Future<void> main(List<String> args) async {
  final logger = Logger('barmaid');
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  final [baseUrl, portString, ...] = args;
  final port = int.parse(portString);

  final tokens = TokenStore.read('tokens.json');
  logger.info('loaded ${tokens.tokens.length} tokens');

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

  final app = Router();

  app.get('/api/packages/versions/new', (Request request) {
    if (tokens.checkAuth(request) case var response?) {
      logger.warning('${request.origin} failed auth check');
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
    if (tokens.checkAuth(request, packageName) case var response?) {
      logger.warning('${request.origin} failed package permission check');
      return response;
    }

    final tokenProps = tokens.getTokenProps(request);
    logger.info('(${tokenProps.owner}) new archive uploaded');

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
    if (tokens.checkAuth(request, package) case var response?) {
      logger.warning('${request.origin} failed package permission check');
      return response;
    }

    final (:parsedPubspec, :pubspecJson, :archiveBytes, :expirationTimer) = uploadCache[uploadUuid]!;
    expirationTimer.cancel();

    final packageIndex = await loadPackageIndex(parsedPubspec.name, allowEmpty: true);
    packageIndex!;

    if (packageIndex.any((element) => element.pubspec['version'] == parsedPubspec.version.toString())) {
      return errorResponse('duplicate_version', 'version ${parsedPubspec.version} already exists');
    }

    final versionUuid = const Uuid().v4();
    packageIndex.add(PackageIndexEntry(
      versionUuid,
      sha256.convert(archiveBytes).toString(),
      pubspecJson,
    ));

    await savePackageIndex(parsedPubspec.name, packageIndex);

    final archiveFile = File(join(repoDir, parsedPubspec.name, '$versionUuid.tar.gz'));
    await archiveFile.writeAsBytes(archiveBytes);

    final tokenProps = tokens.getTokenProps(request);
    logger.info('(${tokenProps.owner}) finalized version ${parsedPubspec.version} of $package');

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

    Map<String, dynamic> encodeVersion(PackageIndexEntry indexEntry) => {
          'version': indexEntry.pubspec['version'],
          'archive_url': '$baseUrl/api/packages/$packageName/archive/${indexEntry.uuid}.tar.gz',
          'archive_sha256': indexEntry.hash,
          'pubspec': indexEntry.pubspec
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
      if (packageIndex == null || !packageIndex.any((element) => element.uuid == versionUuid)) {
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

  final pipeline = const Pipeline().addMiddleware(
    createMiddleware(requestHandler: (request) {
      logger.info('${request.method} /${request.url} from ${request.origin}');
      return null;
    }),
  ).addHandler(app.call);

  await serve(pipeline, 'localhost', port);
  logger.info('serving pub packages on localhost:$port');
}

class AnalysisException implements Exception {
  final String message, errorCode;
  AnalysisException(this.message, this.errorCode);
}

extension on Request {
  String get origin {
    final client = (this.context['shelf.io.connection_info'] as HttpConnectionInfo).remoteAddress.address;
    final origin = StringBuffer();

    if (headers.containsKey(_forwardedHeader)) {
      origin.write(headers[_forwardedHeader]!);
      origin.write(', ');
    }

    return (origin..write(client)).toString();
  }

  static const _forwardedHeader = 'x-forwarded-for';
}
