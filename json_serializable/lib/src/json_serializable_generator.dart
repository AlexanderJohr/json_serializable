// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/analyzer.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:source_gen/source_gen.dart';

import 'type_helper.dart';
import 'type_helpers/date_time_helper.dart';
import 'type_helpers/enum_helper.dart';
import 'type_helpers/iterable_helper.dart';
import 'type_helpers/json_helper.dart';
import 'type_helpers/map_helper.dart';
import 'type_helpers/value_helper.dart';
import 'utils.dart';

class JsonSerializableGenerator
    extends GeneratorForAnnotation<JsonSerializable> {
  static const _coreHelpers = const [
    const IterableHelper(),
    const MapHelper(),
    const EnumHelper(),
    const ValueHelper()
  ];

  static const _defaultHelpers = const [
    const JsonHelper(),
    const DateTimeHelper(),
  ];

  final List<TypeHelper> _typeHelpers;

  final bool includeWriter = true;

  /// Creates an instance of [JsonSerializableGenerator].
  ///
  /// If [typeHelpers] is not provided, two built-in helpers are used:
  /// [JsonHelper] and [DateTimeHelper].
  const JsonSerializableGenerator({List<TypeHelper> typeHelpers})
      : this._typeHelpers = typeHelpers ?? _defaultHelpers;

  /// Creates an instance of [JsonSerializableGenerator].
  ///
  /// [typeHelpers] provides a set of [TypeHelper] that will be used along with
  /// the built-in helpers: [JsonHelper] and [DateTimeHelper].
  factory JsonSerializableGenerator.withDefaultHelpers(
          Iterable<TypeHelper> typeHelpers) =>
      new JsonSerializableGenerator(
          typeHelpers: new List.unmodifiable(
              [typeHelpers, _defaultHelpers].expand((e) => e)));

  @override
  Future<String> generateForAnnotatedElement(
      Element element, ConstantReader annotation, _) async {
    if (element is! ClassElement) {
      var friendlyName = friendlyNameForElement(element);
      throw new InvalidGenerationSourceError(
          'Generator cannot target `$friendlyName`.',
          todo: 'Remove the JsonSerializable annotation from `$friendlyName`.');
    }

    var classElement = element as ClassElement;
    var className = classElement.name;

    // Get all of the fields that need to be assigned
    // TODO: support overriding the field set with an annotation option
    var fieldsList = classElement.fields.where((e) => !e.isStatic).toList();

    var undefinedFields =
        fieldsList.where((fe) => fe.type.isUndefined).toList();
    if (undefinedFields.isNotEmpty) {
      var description =
          undefinedFields.map((fe) => '`${fe.displayName}`').join(', ');

      throw new InvalidGenerationSourceError(
          'At least one field has an invalid type: $description.',
          todo: 'Check names and imports.');
    }

    // Sort these in the order in which they appear in the class
    // Sadly, `classElement.fields` puts properties after fields
    fieldsList.sort((FieldElement a, FieldElement b) {
      int offsetFor(FieldElement e) {
        if (e.getter != null && e.getter.nameOffset != e.nameOffset) {
          assert(e.nameOffset == -1);
          return e.getter.nameOffset;
        }
        return e.nameOffset;
      }

      return offsetFor(a).compareTo(offsetFor(b));
    });

    // Explicitly using `LinkedHashMap` – we want these ordered.
    var fields = new LinkedHashMap<String, FieldElement>.fromIterable(
        fieldsList,
        key: (FieldElement f) => f.name);

    // Get the constructor to use for the factory

    var prefix = '_\$${className}';

    var buffer = new StringBuffer();

    if (annotation.read('createFactory').boolValue) {
      var toSkip = _writeFactory(buffer, classElement, fields, prefix);

      // If there are fields that are final – that are not set via the generated
      // constructor, then don't output them when generating the `toJson` call.
      for (var field in toSkip) {
        fields.remove(field.name);
      }
    }

    if (annotation.read('createToJson').boolValue) {
      var implements = this.includeWriter ? 'implements JsonWriteMySelf ' : '';

      //
      // Generate the mixin class
      //
      buffer.writeln('abstract class ${prefix}SerializerMixin $implements{');

      // write copies of the fields - this allows the toJson method to access
      // the fields of the target class
      for (var field in fields.values) {
        //TODO - handle aliased imports
        buffer.writeln('  ${field.type} get ${field.name};');
      }

      var includeIfNull = annotation.read('includeIfNull').boolValue;

      buffer.writeln('  Map<String, dynamic> toJson() ');
      if (fieldsList.every((e) => _includeIfNull(e, includeIfNull))) {
        // write simple `toJson` method that includes all keys...
        _writeToJsonSimple(buffer, fields.values);
      } else {
        // At least one field should be excluded if null
        _writeToJsonWithNullChecks(buffer, fields.values, includeIfNull);
      }

      if (includeWriter) {
        _writeWriter(buffer, fields.values, includeIfNull);
      }

      // end of the mixin class
      buffer.write('}');
    }

    return buffer.toString();
  }

  void _writeWriter(StringBuffer buffer, Iterable<FieldElement> fields,
      bool classIncludeIfNull) {
    assert(includeWriter);

    var indentedItems = new StringBuffer();
    var items = new StringBuffer();


    var first = true;
    var mightBeFirst = false;

    for (var field in fields) {

      var includeIfNull = _includeIfNull(field, classIncludeIfNull);

      if (first && !includeIfNull) {
        indentedItems.writeln('var first = true;');
        items.writeln('var first = true;');
        mightBeFirst = true;
      }

      if (!includeIfNull) {
        indentedItems.writeln('if (${field.name} != null) {');
        items.writeln('if (${field.name} != null) {');
      }

      if (mightBeFirst) {
        indentedItems.writeln('''        if (first) {
          first = false;
        } else {
          writer.writeString(',\\n');
        }''');
        items.writeln('''        if (first) {
          first = false;
        } else {
          writer.writeString(',\"');
        }''');
        if (includeIfNull) {
          mightBeFirst = false;
        }
      } else if(!first) {
        // Write normal separators
        indentedItems.writeln("writer.writeString(',\\n');");
        items.writeln("writer.writeString(',\"');");
      }

      first = false;


      indentedItems.writeln('writer.writeIndentation();');
      indentedItems.writeln("writer.writeString('\"');");
      indentedItems
          .writeln('writer.writeStringContent(${_safeNameAccess(field)});');
      indentedItems.writeln("writer.writeString('\": ');");
      indentedItems.writeln('writer.writeObject(${_serializeField(field )});');
      indentedItems.writeln();

      items.writeln('writer.writeStringContent(${_safeNameAccess(field)});');
      items.writeln("writer.writeString('\":');");
      items.writeln('writer.writeObject(${_serializeField(field )});');

      if (!includeIfNull) {
        // close if block
        indentedItems.writeln('}');
        items.writeln('}');
      }


    }

    buffer.writeln('''

@override
bool writeJson(JsonWriter writer) {
  if (writer.isPretty) {
    writer.writeString('{\\n');

    writer.increaseIndent();

    $indentedItems    
    
    writer.writeString('\\n');

    writer.decreaseIndent();

    writer.writeIndentation();
  } else {
    writer.writeString('{');
    $items
  }
  writer.writeString('}');
''');

    buffer.writeln('''return true;
    }''');
  }

  void _writeToJsonWithNullChecks(StringBuffer buffer,
      Iterable<FieldElement> fields, bool classIncludeIfNull) {
    buffer.writeln('{');

    buffer.writeln('var $toJsonMapVarName = <String, dynamic>{');

    // Note that the map literal is left open above. As long as target fields
    // don't need to be intercepted by the `only if null` logic, write them
    // to the map literal directly. In theory, should allow more efficient
    // serialization.
    var directWrite = true;

    for (var field in fields) {
      var safeFieldAccess = field.name;
      var safeJsonKeyString = _safeNameAccess(field);

      // If `fieldName` collides with one of the local helpers, prefix
      // access with `this.`.
      if (safeFieldAccess == toJsonMapVarName ||
          safeFieldAccess == toJsonMapHelperName) {
        safeFieldAccess = 'this.$safeFieldAccess';
      }

      if (_includeIfNull(field, classIncludeIfNull)) {
        if (directWrite) {
          buffer.writeln('$safeJsonKeyString : '
              '${_serializeField(field, accessOverride:  safeFieldAccess)},');
        } else {
          buffer.writeln('$toJsonMapVarName[$safeJsonKeyString] = '
              '${_serializeField(field, accessOverride:  safeFieldAccess)};');
        }
      } else {
        if (directWrite) {
          // close the still-open map literal
          buffer.writeln('};');
          buffer.writeln();

          // write the helper to be used by all following null-excluding
          // fields
          buffer.writeln('''
void $toJsonMapHelperName(String key, dynamic value) {
  if (value != null) {
    $toJsonMapVarName[key] = value;
  }
}''');
          directWrite = false;
        }
        buffer.writeln('$toJsonMapHelperName($safeJsonKeyString, '
            '${_serializeField(field, accessOverride:  safeFieldAccess)});');
      }
    }

    buffer.writeln('return $toJsonMapVarName;');

    buffer.writeln('}');
  }

  void _writeToJsonSimple(StringBuffer buffer, Iterable<FieldElement> fields) {
    buffer.writeln('=> <String, dynamic>{');

    var pairs = <String>[];
    for (var field in fields) {
      pairs.add('${_safeNameAccess(field)}: ${_serializeField(field )}');
    }
    buffer.writeAll(pairs, ',\n');

    buffer.writeln('  };');
  }

  /// Returns the set of fields that are not written to via constructors.
  Set<FieldElement> _writeFactory(
      StringBuffer buffer,
      ClassElement classElement,
      Map<String, FieldElement> fields,
      String prefix) {
    // creating a copy so it can be mutated
    var fieldsToSet = new Map<String, FieldElement>.from(fields);
    var className = classElement.displayName;
    // Create the factory method

    // Get the default constructor
    // TODO: allow overriding the ctor used for the factory
    var ctor = classElement.unnamedConstructor;
    if (ctor == null) {
      throw new UnsupportedError(
          'The class `${classElement.name}` has no default constructor.');
    }

    var ctorArguments = <ParameterElement>[];
    var ctorNamedArguments = <ParameterElement>[];

    for (var arg in ctor.parameters) {
      var field = fields[arg.name];

      if (field == null) {
        if (arg.parameterKind == ParameterKind.REQUIRED) {
          throw new UnsupportedError('Cannot populate the required constructor '
              'argument: ${arg.displayName}.');
        }
        continue;
      }

      // TODO: validate that the types match!
      if (arg.parameterKind == ParameterKind.NAMED) {
        ctorNamedArguments.add(arg);
      } else {
        ctorArguments.add(arg);
      }
      fieldsToSet.remove(arg.name);
    }

    var undefinedArgs = [ctorArguments, ctorNamedArguments]
        .expand((l) => l)
        .where((pe) => pe.type.isUndefined)
        .toList();
    if (undefinedArgs.isNotEmpty) {
      var description =
          undefinedArgs.map((fe) => '`${fe.displayName}`').join(', ');

      throw new InvalidGenerationSourceError(
          'At least one constructor argument has an invalid type: $description.',
          todo: 'Check names and imports.');
    }

    // these are fields to skip – now to find them
    var finalFields =
        fieldsToSet.values.where((field) => field.isFinal).toSet();

    for (var finalField in finalFields) {
      var value = fieldsToSet.remove(finalField.name);
      assert(value == finalField);
    }

    //
    // Generate the static factory method
    //
    buffer.writeln();
    buffer
        .writeln('$className ${prefix}FromJson(Map<String, dynamic> json) =>');
    buffer.write('    new $className(');
    buffer.writeAll(
        ctorArguments.map((paramElement) => _deserializeForField(
            fields[paramElement.name],
            ctorParam: paramElement)),
        ', ');
    if (ctorArguments.isNotEmpty && ctorNamedArguments.isNotEmpty) {
      buffer.write(', ');
    }
    buffer.writeAll(
        ctorNamedArguments.map((paramElement) =>
            '${paramElement.name}: ' +
            _deserializeForField(fields[paramElement.name],
                ctorParam: paramElement)),
        ', ');

    buffer.write(')');
    if (fieldsToSet.isEmpty) {
      buffer.writeln(';');
    } else {
      for (var field in fieldsToSet.values) {
        buffer.writeln();
        buffer.write('      ..${field.name} = ');
        buffer.write(_deserializeForField(field));
      }
      buffer.writeln(';');
    }
    buffer.writeln();

    return finalFields;
  }

  Iterable<TypeHelper> get _allHelpers =>
      [_typeHelpers, _coreHelpers].expand((e) => e);

  String _serializeField(FieldElement field, {String accessOverride}) {
    accessOverride ??= field.name;
    try {
      return _serialize(field.type, accessOverride, _nullable(field));
    } on UnsupportedTypeError {
      throw new InvalidGenerationSourceError(
          'Could not generate `toJson` code for '
          '`${friendlyNameForElement(field)}`.',
          todo: 'Make sure all of the types are serializable.');
    }
  }

  /// [expression] may be just the name of the field or it may an expression
  /// representing the serialization of a value.
  String _serialize(DartType targetType, String expression, bool nullable) =>
      _allHelpers
          .map((h) => h.serialize(targetType, expression, nullable, _serialize))
          .firstWhere((r) => r != null,
              orElse: () =>
                  throw new UnsupportedTypeError(targetType, expression));

  String _deserializeForField(FieldElement field,
      {ParameterElement ctorParam}) {
    var jsonKey = _safeNameAccess(field);

    var targetType = ctorParam?.type ?? field.type;

    try {
      return _deserialize(targetType, 'json[$jsonKey]', _nullable(field));
    } on UnsupportedTypeError {
      throw new InvalidGenerationSourceError(
          'Could not generate fromJson code for '
          '`${friendlyNameForElement(field)}`.',
          todo: 'Make sure all of the types are serializable.');
    }
  }

  String _deserialize(DartType targetType, String expression, bool nullable) =>
      _allHelpers
          .map((th) =>
              th.deserialize(targetType, expression, nullable, _deserialize))
          .firstWhere((r) => r != null,
              orElse: () =>
                  throw new UnsupportedTypeError(targetType, expression));
}

String _safeNameAccess(FieldElement field) {
  var name = _jsonKeyFor(field).name ?? field.name;
  // TODO(kevmoo): JsonKey.name could also have quotes and other silly.
  return name.contains(r'$') ? "r'${name}'" : "'${name}'";
}

/// Returns `true` if the field should be treated as potentially nullable.
///
/// If no [JsonKey] annotation is present on the field, `true` is returned.
bool _nullable(FieldElement field) => _jsonKeyFor(field).nullable;

bool _includeIfNull(FieldElement element, bool parentValue) =>
    _jsonKeyFor(element).includeIfNull ?? parentValue;

JsonKey _jsonKeyFor(FieldElement element) {
  var key = _jsonKeyExpando[element];

  if (key == null) {
    // If an annotation exists on `element` the source is a 'real' field.
    // If the result is `null`, check the getter – it is a property.
    // TODO(kevmoo) setters: github.com/dart-lang/json_serializable/issues/24
    var obj = _jsonKeyChecker.firstAnnotationOfExact(element) ??
        _jsonKeyChecker.firstAnnotationOfExact(element.getter);

    _jsonKeyExpando[element] = key = obj == null
        ? const JsonKey()
        : new JsonKey(
            name: obj.getField('name').toStringValue(),
            nullable: obj.getField('nullable').toBoolValue(),
            includeIfNull: obj.getField('includeIfNull').toBoolValue());
  }

  return key;
}

final _jsonKeyExpando = new Expando<JsonKey>();

final _jsonKeyChecker = new TypeChecker.fromRuntime(JsonKey);
