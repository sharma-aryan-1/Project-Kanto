// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'species.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetSpeciesCollection on Isar {
  IsarCollection<Species> get species => this.collection();
}

const SpeciesSchema = CollectionSchema(
  name: r'Species',
  id: -1724512414814962385,
  properties: {
    r'caughtDate': PropertySchema(
      id: 0,
      name: r'caughtDate',
      type: IsarType.dateTime,
    ),
    r'classId': PropertySchema(
      id: 1,
      name: r'classId',
      type: IsarType.long,
    ),
    r'commonName': PropertySchema(
      id: 2,
      name: r'commonName',
      type: IsarType.string,
    ),
    r'isCaught': PropertySchema(
      id: 3,
      name: r'isCaught',
      type: IsarType.bool,
    ),
    r'loreDescription': PropertySchema(
      id: 4,
      name: r'loreDescription',
      type: IsarType.string,
    ),
    r'scientificName': PropertySchema(
      id: 5,
      name: r'scientificName',
      type: IsarType.string,
    )
  },
  estimateSize: _speciesEstimateSize,
  serialize: _speciesSerialize,
  deserialize: _speciesDeserialize,
  deserializeProp: _speciesDeserializeProp,
  idName: r'id',
  indexes: {
    r'classId': IndexSchema(
      id: 5352960816261817663,
      name: r'classId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'classId',
          type: IndexType.value,
          caseSensitive: false,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _speciesGetId,
  getLinks: _speciesGetLinks,
  attach: _speciesAttach,
  version: '3.1.0+1',
);

int _speciesEstimateSize(
  Species object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.commonName.length * 3;
  bytesCount += 3 + object.loreDescription.length * 3;
  bytesCount += 3 + object.scientificName.length * 3;
  return bytesCount;
}

void _speciesSerialize(
  Species object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeDateTime(offsets[0], object.caughtDate);
  writer.writeLong(offsets[1], object.classId);
  writer.writeString(offsets[2], object.commonName);
  writer.writeBool(offsets[3], object.isCaught);
  writer.writeString(offsets[4], object.loreDescription);
  writer.writeString(offsets[5], object.scientificName);
}

Species _speciesDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = Species();
  object.caughtDate = reader.readDateTimeOrNull(offsets[0]);
  object.classId = reader.readLong(offsets[1]);
  object.commonName = reader.readString(offsets[2]);
  object.id = id;
  object.isCaught = reader.readBool(offsets[3]);
  object.loreDescription = reader.readString(offsets[4]);
  object.scientificName = reader.readString(offsets[5]);
  return object;
}

P _speciesDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readBool(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _speciesGetId(Species object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _speciesGetLinks(Species object) {
  return [];
}

void _speciesAttach(IsarCollection<dynamic> col, Id id, Species object) {
  object.id = id;
}

extension SpeciesQueryWhereSort on QueryBuilder<Species, Species, QWhere> {
  QueryBuilder<Species, Species, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }

  QueryBuilder<Species, Species, QAfterWhere> anyClassId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        const IndexWhereClause.any(indexName: r'classId'),
      );
    });
  }
}

extension SpeciesQueryWhere on QueryBuilder<Species, Species, QWhereClause> {
  QueryBuilder<Species, Species, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> idGreaterThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> idLessThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> classIdEqualTo(
      int classId) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'classId',
        value: [classId],
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> classIdNotEqualTo(
      int classId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'classId',
              lower: [],
              upper: [classId],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'classId',
              lower: [classId],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'classId',
              lower: [classId],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'classId',
              lower: [],
              upper: [classId],
              includeUpper: false,
            ));
      }
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> classIdGreaterThan(
    int classId, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'classId',
        lower: [classId],
        includeLower: include,
        upper: [],
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> classIdLessThan(
    int classId, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'classId',
        lower: [],
        upper: [classId],
        includeUpper: include,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterWhereClause> classIdBetween(
    int lowerClassId,
    int upperClassId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.between(
        indexName: r'classId',
        lower: [lowerClassId],
        includeLower: includeLower,
        upper: [upperClassId],
        includeUpper: includeUpper,
      ));
    });
  }
}

extension SpeciesQueryFilter
    on QueryBuilder<Species, Species, QFilterCondition> {
  QueryBuilder<Species, Species, QAfterFilterCondition> caughtDateIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'caughtDate',
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> caughtDateIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'caughtDate',
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> caughtDateEqualTo(
      DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'caughtDate',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> caughtDateGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'caughtDate',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> caughtDateLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'caughtDate',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> caughtDateBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'caughtDate',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> classIdEqualTo(
      int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'classId',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> classIdGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'classId',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> classIdLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'classId',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> classIdBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'classId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'commonName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'commonName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'commonName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'commonName',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'commonName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'commonName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameContains(
      String value,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'commonName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameMatches(
      String pattern,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'commonName',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'commonName',
        value: '',
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> commonNameIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'commonName',
        value: '',
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> isCaughtEqualTo(
      bool value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'isCaught',
        value: value,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> loreDescriptionEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'loreDescription',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      loreDescriptionGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'loreDescription',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> loreDescriptionLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'loreDescription',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> loreDescriptionBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'loreDescription',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      loreDescriptionStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'loreDescription',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> loreDescriptionEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'loreDescription',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> loreDescriptionContains(
      String value,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'loreDescription',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> loreDescriptionMatches(
      String pattern,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'loreDescription',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      loreDescriptionIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'loreDescription',
        value: '',
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      loreDescriptionIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'loreDescription',
        value: '',
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> scientificNameEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scientificName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      scientificNameGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'scientificName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> scientificNameLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'scientificName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> scientificNameBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'scientificName',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      scientificNameStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'scientificName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> scientificNameEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'scientificName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> scientificNameContains(
      String value,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'scientificName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition> scientificNameMatches(
      String pattern,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'scientificName',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      scientificNameIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'scientificName',
        value: '',
      ));
    });
  }

  QueryBuilder<Species, Species, QAfterFilterCondition>
      scientificNameIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'scientificName',
        value: '',
      ));
    });
  }
}

extension SpeciesQueryObject
    on QueryBuilder<Species, Species, QFilterCondition> {}

extension SpeciesQueryLinks
    on QueryBuilder<Species, Species, QFilterCondition> {}

extension SpeciesQuerySortBy on QueryBuilder<Species, Species, QSortBy> {
  QueryBuilder<Species, Species, QAfterSortBy> sortByCaughtDate() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'caughtDate', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByCaughtDateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'caughtDate', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByClassId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'classId', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByClassIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'classId', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByCommonName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'commonName', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByCommonNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'commonName', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByIsCaught() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCaught', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByIsCaughtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCaught', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByLoreDescription() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'loreDescription', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByLoreDescriptionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'loreDescription', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByScientificName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scientificName', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> sortByScientificNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scientificName', Sort.desc);
    });
  }
}

extension SpeciesQuerySortThenBy
    on QueryBuilder<Species, Species, QSortThenBy> {
  QueryBuilder<Species, Species, QAfterSortBy> thenByCaughtDate() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'caughtDate', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByCaughtDateDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'caughtDate', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByClassId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'classId', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByClassIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'classId', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByCommonName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'commonName', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByCommonNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'commonName', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByIsCaught() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCaught', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByIsCaughtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'isCaught', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByLoreDescription() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'loreDescription', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByLoreDescriptionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'loreDescription', Sort.desc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByScientificName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scientificName', Sort.asc);
    });
  }

  QueryBuilder<Species, Species, QAfterSortBy> thenByScientificNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'scientificName', Sort.desc);
    });
  }
}

extension SpeciesQueryWhereDistinct
    on QueryBuilder<Species, Species, QDistinct> {
  QueryBuilder<Species, Species, QDistinct> distinctByCaughtDate() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'caughtDate');
    });
  }

  QueryBuilder<Species, Species, QDistinct> distinctByClassId() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'classId');
    });
  }

  QueryBuilder<Species, Species, QDistinct> distinctByCommonName(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'commonName', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<Species, Species, QDistinct> distinctByIsCaught() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'isCaught');
    });
  }

  QueryBuilder<Species, Species, QDistinct> distinctByLoreDescription(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'loreDescription',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<Species, Species, QDistinct> distinctByScientificName(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'scientificName',
          caseSensitive: caseSensitive);
    });
  }
}

extension SpeciesQueryProperty
    on QueryBuilder<Species, Species, QQueryProperty> {
  QueryBuilder<Species, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<Species, DateTime?, QQueryOperations> caughtDateProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'caughtDate');
    });
  }

  QueryBuilder<Species, int, QQueryOperations> classIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'classId');
    });
  }

  QueryBuilder<Species, String, QQueryOperations> commonNameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'commonName');
    });
  }

  QueryBuilder<Species, bool, QQueryOperations> isCaughtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'isCaught');
    });
  }

  QueryBuilder<Species, String, QQueryOperations> loreDescriptionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'loreDescription');
    });
  }

  QueryBuilder<Species, String, QQueryOperations> scientificNameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'scientificName');
    });
  }
}
