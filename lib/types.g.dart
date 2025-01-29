// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'types.dart';

// **************************************************************************
// StructEndecGenerator
// **************************************************************************

// static final Endec<PackageIndexEntry> endec = _$PackageIndexEntryEndec;
final _$PackageIndexEntryEndec = structEndec<PackageIndexEntry>().with3Fields(
  Endec.string.fieldOf('uuid', (struct) => struct.uuid),
  Endec.string.fieldOf('hash', (struct) => struct.hash),
  _jsonObjectEndec().fieldOf('pubspec', (struct) => struct.pubspec),
  (uuid, hash, pubspec) => PackageIndexEntry(uuid, hash, pubspec),
);

// static final Endec<TokenProperties> endec = _$TokenPropertiesEndec;
final _$TokenPropertiesEndec = structEndec<TokenProperties>().with2Fields(
  Endec.string.fieldOf('owner', (struct) => struct.owner),
  Endec.string
      .setOf()
      .fieldOf('authorized_packages', (struct) => struct.authorizedPackages),
  (owner, authorizedPackages) => TokenProperties(owner, authorizedPackages),
);
