//
// Created by Krzysztof Zablocki on 31/12/2016.
// Copyright (c) 2016 Pixle. All rights reserved.
//

import Foundation

private func currentTimestamp() -> TimeInterval {
    return CFAbsoluteTimeGetCurrent()
}

/// Responsible for composing results of `FileParser`.
public enum Composer {

    /// Performs final processing of discovered types:
    /// - extends types with their corresponding extensions;
    /// - replaces typealiases with actual types
    /// - finds actual types for variables and enums raw values
    /// - filters out any private types and extensions
    ///
    /// - Parameter parserResult: Result of parsing source code.
    /// - Returns: Final types and extensions of unknown types.
    public static func uniqueTypesAndFunctions(_ parserResult: FileParserResult) -> (types: [Type], functions: [SourceryMethod], typealiases: [Typealias]) {
        let state = State(parserResult: parserResult)

        let resolveType = { (typeName: TypeName, containingType: Type?) -> Type? in
            return self.resolveType(typeName: typeName, containingType: containingType, state: state)
        }

        /// Resolve typealiases
        let typealiases = Array(state.unresolvedTypealiases.values)
        typealiases.forEach { alias in
            alias.type = resolveType(alias.typeName, alias.parent)
        }

        let types = state.unifyTypes()

        let resolutionStart = currentTimestamp()

        types.parallelPerform { type in
            type.variables.forEach {
                resolveVariableTypes($0, of: type, resolve: resolveType)
            }
            type.methods.forEach {
                resolveMethodTypes($0, of: type, resolve: resolveType)
            }
            type.subscripts.forEach {
                resolveSubscriptTypes($0, of: type, resolve: resolveType)
            }

            if let enumeration = type as? Enum {
                resolveEnumTypes(enumeration, types: state.typeMap, resolve: resolveType)
            }

            if let composition = type as? ProtocolComposition {
                resolveProtocolCompositionTypes(composition, resolve: resolveType)
            }

            if let sourceryProtocol = type as? SourceryProtocol {
                resolveProtocolTypes(sourceryProtocol, resolve: resolveType)
            }
        }

        state.functions.parallelPerform { function in
            resolveMethodTypes(function, of: nil, resolve: resolveType)
        }

        Log.benchmark("resolution took \(currentTimestamp() - resolutionStart)")

        updateTypeRelationships(types: types)

        return (
            types: types.sorted { $0.globalName < $1.globalName },
            functions: state.functions.sorted { $0.name < $1.name },
            typealiases: typealiases.sorted(by: { $0.name < $1.name })
        )
    }

    private static func resolveType(typeName: TypeName, containingType: Type?, state: State) -> Type? {
        let resolveTypeWithName = { (typeName: TypeName) -> Type? in
            return self.resolveType(typeName: typeName, containingType: containingType, state: state)
        }

        let unique = state.typeMap

        if let name = typeName.actualTypeName {
            let resolvedIdentifier = name.generic?.name ?? name.unwrappedTypeName
            return unique[resolvedIdentifier]
        }

        let retrievedName = self.actualTypeName(for: typeName, containingType: containingType, state: state)
        let lookupName = retrievedName ?? typeName

        if let tuple = lookupName.tuple {
            var needsUpdate = false

            tuple.elements.forEach { tupleElement in
                tupleElement.type = resolveTypeWithName(tupleElement.typeName)
                if tupleElement.typeName.actualTypeName != nil {
                    needsUpdate = true
                }
            }

            if needsUpdate || retrievedName != nil {
                let tupleCopy = TupleType(name: tuple.name, elements: tuple.elements)
                tupleCopy.elements.forEach {
                    $0.typeName = $0.actualTypeName ?? $0.typeName
                    $0.typeName.actualTypeName = nil
                }
                tupleCopy.name = tupleCopy.elements.asTypeName

                typeName.tuple = tupleCopy // TODO: really don't like this old behaviour
                typeName.actualTypeName = TypeName(name: tupleCopy.name,
                                                   isOptional: typeName.isOptional,
                                                   isImplicitlyUnwrappedOptional: typeName.isImplicitlyUnwrappedOptional,
                                                   tuple: tupleCopy,
                                                   array: lookupName.array,
                                                   dictionary: lookupName.dictionary,
                                                   closure: lookupName.closure,
                                                   generic: lookupName.generic
                )
            }
            return nil
        } else
        if let array = lookupName.array {
            array.elementType = resolveTypeWithName(array.elementTypeName)

            if array.elementTypeName.actualTypeName != nil || retrievedName != nil {
                let array = ArrayType(name: array.name, elementTypeName: array.elementTypeName, elementType: array.elementType)
                array.elementTypeName = array.elementTypeName.actualTypeName ?? array.elementTypeName
                array.elementTypeName.actualTypeName = nil
                array.name = array.asSource
                typeName.array = array // TODO: really don't like this old behaviour
                typeName.generic = array.asGeneric // TODO: really don't like this old behaviour

                typeName.actualTypeName = TypeName(name: array.name,
                                                   isOptional: typeName.isOptional,
                                                   isImplicitlyUnwrappedOptional: typeName.isImplicitlyUnwrappedOptional,
                                                   tuple: lookupName.tuple,
                                                   array: array,
                                                   dictionary: lookupName.dictionary,
                                                   closure: lookupName.closure,
                                                   generic: typeName.generic
                )
            }
        } else
        if let dictionary = lookupName.dictionary {
            dictionary.keyType = resolveTypeWithName(dictionary.keyTypeName)
            dictionary.valueType = resolveTypeWithName(dictionary.valueTypeName)

            if dictionary.keyTypeName.actualTypeName != nil || dictionary.valueTypeName.actualTypeName != nil || retrievedName != nil {
                let dictionary = DictionaryType(name: dictionary.name, valueTypeName: dictionary.valueTypeName, valueType: dictionary.valueType, keyTypeName: dictionary.keyTypeName, keyType: dictionary.keyType)
                dictionary.keyTypeName = dictionary.keyTypeName.actualTypeName ?? dictionary.keyTypeName
                dictionary.keyTypeName.actualTypeName = nil // TODO: really don't like this old behaviour
                dictionary.valueTypeName = dictionary.valueTypeName.actualTypeName ?? dictionary.valueTypeName
                dictionary.valueTypeName.actualTypeName = nil // TODO: really don't like this old behaviour

                dictionary.name = dictionary.asSource

                typeName.dictionary = dictionary // TODO: really don't like this old behaviour
                typeName.generic = dictionary.asGeneric // TODO: really don't like this old behaviour

                typeName.actualTypeName = TypeName(name: dictionary.asSource,
                                                   isOptional: typeName.isOptional,
                                                   isImplicitlyUnwrappedOptional: typeName.isImplicitlyUnwrappedOptional,
                                                   tuple: lookupName.tuple,
                                                   array: lookupName.array,
                                                   dictionary: dictionary,
                                                   closure: lookupName.closure,
                                                   generic: dictionary.asGeneric
                )
            }
        } else
        if let closure = lookupName.closure {
            var needsUpdate = false

            closure.returnType = resolveTypeWithName(closure.returnTypeName)
            closure.parameters.forEach { parameter in
                parameter.type = resolveTypeWithName(parameter.typeName)
                if parameter.typeName.actualTypeName != nil {
                    needsUpdate = true
                }
            }

            if closure.returnTypeName.actualTypeName != nil || needsUpdate || retrievedName != nil {
                typeName.closure = closure // TODO: really don't like this old behaviour

                typeName.actualTypeName = TypeName(name: closure.asSource,
                                                   isOptional: typeName.isOptional,
                                                   isImplicitlyUnwrappedOptional: typeName.isImplicitlyUnwrappedOptional,
                                                   tuple: lookupName.tuple,
                                                   array: lookupName.array,
                                                   dictionary: lookupName.dictionary,
                                                   closure: closure,
                                                   generic: lookupName.generic
                )
            }

            return nil
        } else
        if let generic = lookupName.generic {
            var needsUpdate = false

            generic.typeParameters.forEach { parameter in
                parameter.type = resolveTypeWithName(parameter.typeName)
                if parameter.typeName.actualTypeName != nil {
                    needsUpdate = true
                }
            }

            if needsUpdate || retrievedName != nil {
                let generic = GenericType(name: generic.name, typeParameters: generic.typeParameters)
                generic.typeParameters.forEach {
                    $0.typeName = $0.typeName.actualTypeName ?? $0.typeName
                    $0.typeName.actualTypeName = nil // TODO: really don't like this old behaviour
                }
                typeName.generic = generic // TODO: really don't like this old behaviour
                typeName.array = lookupName.array // TODO: really don't like this old behaviour
                typeName.dictionary = lookupName.dictionary // TODO: really don't like this old behaviour

                let params = generic.typeParameters.map { $0.typeName.asSource }.joined(separator: ", ")

                typeName.actualTypeName = TypeName(name: "\(generic.name)<\(params)>",
                                                   isOptional: typeName.isOptional,
                                                   isImplicitlyUnwrappedOptional: typeName.isImplicitlyUnwrappedOptional,
                                                   tuple: lookupName.tuple,
                                                   array: lookupName.array, // TODO: asArray
                                                   dictionary: lookupName.dictionary, // TODO: asDictionary
                                                   closure: lookupName.closure,
                                                   generic: generic
                )
            }
        }

        if let aliasedName = (typeName.actualTypeName ?? retrievedName), aliasedName.unwrappedTypeName != typeName.unwrappedTypeName {
            typeName.actualTypeName = aliasedName
        }

        let finalLookup = typeName.actualTypeName ?? typeName
        let resolvedIdentifier = finalLookup.generic?.name ?? finalLookup.unwrappedTypeName

        // should we cache resolved typenames?
        return unique[resolvedIdentifier]
    }

    typealias TypeResolver = (TypeName, Type?) -> Type?

    private static func resolveVariableTypes(_ variable: Variable, of type: Type, resolve: TypeResolver) {
        variable.type = resolve(variable.typeName, type)

        /// The actual `definedInType` is assigned in `uniqueTypes` but we still
        /// need to resolve the type to correctly parse typealiases
        /// @see https://github.com/krzysztofzablocki/Sourcery/pull/374
        if let definedInTypeName = variable.definedInTypeName {
            _ = resolve(definedInTypeName, type)
        }
    }

    private static func resolveSubscriptTypes(_ subscript: Subscript, of type: Type, resolve: TypeResolver) {
        `subscript`.parameters.forEach { (parameter) in
            parameter.type = resolve(parameter.typeName, type)
        }

        `subscript`.returnType = resolve(`subscript`.returnTypeName, type)
        if let definedInTypeName = `subscript`.definedInTypeName {
            _ = resolve(definedInTypeName, type)
        }
    }

    private static func resolveMethodTypes(_ method: SourceryMethod, of type: Type?, resolve: TypeResolver) {
        method.parameters.forEach { parameter in
            parameter.type = resolve(parameter.typeName, type)
        }

        /// The actual `definedInType` is assigned in `uniqueTypes` but we still
        /// need to resolve the type to correctly parse typealiases
        /// @see https://github.com/krzysztofzablocki/Sourcery/pull/374
        var definedInType: Type?
        if let definedInTypeName = method.definedInTypeName {
            definedInType = resolve(definedInTypeName, type)
        }

        guard !method.returnTypeName.isVoid else { return }

        if method.isInitializer || method.isFailableInitializer {
            method.returnType = definedInType
            if let type = method.actualDefinedInTypeName {
                if method.isFailableInitializer {
                    method.returnTypeName = TypeName(
                        name: type.name,
                        isOptional: true,
                        isImplicitlyUnwrappedOptional: false,
                        tuple: type.tuple,
                        array: type.array,
                        dictionary: type.dictionary,
                        closure: type.closure,
                        generic: type.generic,
                        isProtocolComposition: type.isProtocolComposition
                    )
                } else if method.isInitializer {
                    method.returnTypeName = type
                }
            }
        } else {
            method.returnType = resolve(method.returnTypeName, type)
        }
    }

    private static func resolveEnumTypes(_ enumeration: Enum, types: [String: Type], resolve: TypeResolver) {
        enumeration.cases.forEach { enumCase in
            enumCase.associatedValues.forEach { associatedValue in
                associatedValue.type = resolve(associatedValue.typeName, enumeration)
            }
        }

        guard enumeration.hasRawType else { return }

        if let rawValueVariable = enumeration.variables.first(where: { $0.name == "rawValue" && !$0.isStatic }) {
            enumeration.rawTypeName = rawValueVariable.actualTypeName
            enumeration.rawType = rawValueVariable.type
        } else if let rawTypeName = enumeration.inheritedTypes.first {
            // enums with no cases or enums with cases that contain associated values can't have raw type
            guard !enumeration.cases.isEmpty,
                  !enumeration.hasAssociatedValues else {
                return enumeration.rawTypeName = nil
            }

            if let rawTypeCandidate = types[rawTypeName] {
                if !((rawTypeCandidate is SourceryProtocol) || (rawTypeCandidate is ProtocolComposition)) {
                    enumeration.rawTypeName = TypeName(rawTypeName)
                    enumeration.rawType = rawTypeCandidate
                }
            } else {
                enumeration.rawTypeName = TypeName(rawTypeName)
            }
        }
    }

    private static func resolveProtocolCompositionTypes(_ protocolComposition: ProtocolComposition, resolve: TypeResolver) {
        let composedTypes = protocolComposition.composedTypeNames.compactMap { typeName in
            resolve(typeName, protocolComposition)
        }

        protocolComposition.composedTypes = composedTypes
    }

    private static func resolveProtocolTypes(_ sourceryProtocol: SourceryProtocol, resolve: TypeResolver) {
        sourceryProtocol.associatedTypes.forEach { (_, value) in
            guard let typeName = value.typeName,
                  let type = resolve(typeName, sourceryProtocol)
            else { return }
            value.type = type
        }

        sourceryProtocol.genericRequirements.forEach { requirment in
            if let knownAssociatedType = sourceryProtocol.associatedTypes[requirment.leftType.name] {
                requirment.leftType = knownAssociatedType
            }
            requirment.rightType.type = resolve(requirment.rightType.typeName, sourceryProtocol)
        }
    }

    private static func actualTypeName(for typeName: TypeName,
                                       containingType: Type? = nil,
                                       state: State) -> TypeName? {
        let unique = state.typeMap
        let modules = state.modules
        let typealiases = state.resolvedTypealiases

        var unwrapped = typeName.unwrappedTypeName
        if let generic = typeName.generic {
            unwrapped = generic.name
        }

        guard let aliased = state.resolveGlobalName(for: unwrapped, containingType: containingType, unique: unique, modules: modules, typealiases: typealiases) else {
            return nil
        }

        /// TODO: verify
        let generic = typeName.generic.map { GenericType(name: $0.name, typeParameters: $0.typeParameters) }
        generic?.name = aliased.name
        let dictionary = typeName.dictionary.map { DictionaryType(name: $0.name, valueTypeName: $0.valueTypeName, valueType: $0.valueType, keyTypeName: $0.keyTypeName, keyType: $0.keyType) }
        dictionary?.name = aliased.name
        let array = typeName.array.map { ArrayType(name: $0.name, elementTypeName: $0.elementTypeName, elementType: $0.elementType) }
        array?.name = aliased.name

        return TypeName(name: aliased.name,
                        isOptional: typeName.isOptional,
                        isImplicitlyUnwrappedOptional: typeName.isImplicitlyUnwrappedOptional,
                        tuple: aliased.typealias?.typeName.tuple ?? typeName.tuple, // TODO: verify
                        array: aliased.typealias?.typeName.array ?? array,
                        dictionary: aliased.typealias?.typeName.dictionary ?? dictionary,
                        closure: aliased.typealias?.typeName.closure ?? typeName.closure,
                        generic: aliased.typealias?.typeName.generic ?? generic
        )
    }

    private static func updateTypeRelationships(types: [Type]) {
        var typesByName = [String: Type]()
        types.forEach { typesByName[$0.globalName] = $0 }

        var processed = [String: Bool]()
        types.forEach { type in
            if let type = type as? Class, let supertype = type.inheritedTypes.first.flatMap({ typesByName[$0] }) as? Class {
                type.supertype = supertype
            }
            processed[type.globalName] = true
            updateTypeRelationship(for: type, typesByName: typesByName, processed: &processed)
        }
    }

    private static func findBaseType(for type: Type, name: String, typesByName: [String: Type]) -> Type? {
        if let baseType = typesByName[name] {
            return baseType
        }
        if let module = type.module, let baseType = typesByName["\(module).\(name)"] {
            return baseType
        }
        for importModule in type.imports {
            if let baseType = typesByName["\(importModule).\(name)"] {
                return baseType
            }
        }
        return nil
    }

    private static func updateTypeRelationship(for type: Type, typesByName: [String: Type], processed: inout [String: Bool]) {
        type.based.keys.forEach { name in
            guard let baseType = findBaseType(for: type, name: name, typesByName: typesByName) else { return }
            let globalName = baseType.globalName
            if processed[globalName] != true {
                processed[globalName] = true
                updateTypeRelationship(for: baseType, typesByName: typesByName, processed: &processed)
            }

            baseType.based.keys.forEach { type.based[$0] = $0 }
            baseType.basedTypes.forEach { type.basedTypes[$0.key] = $0.value }
            baseType.inherits.forEach { type.inherits[$0.key] = $0.value }
            baseType.implements.forEach { type.implements[$0.key] = $0.value }

            if baseType is Class {
                type.inherits[globalName] = baseType
            } else if let baseProtocol = baseType as? SourceryProtocol {
                type.implements[globalName] = baseProtocol
                if let extendingProtocol = type as? SourceryProtocol {
                    baseProtocol.associatedTypes.forEach {
                        if extendingProtocol.associatedTypes[$0.key] == nil {
                            extendingProtocol.associatedTypes[$0.key] = $0.value
                        }
                    }
                }
            } else if baseType is ProtocolComposition {
                // TODO: associated types?
                type.implements[globalName] = baseType
            }

            type.basedTypes[globalName] = baseType
        }
    }
}