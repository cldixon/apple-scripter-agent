import Foundation

/// The parts of a scripting dictionary (sdef) the agent needs: suites with their classes,
/// commands and enumerations. Hidden entries are left out.
public struct SdefDictionary: Sendable, Equatable {
    public var title: String
    public var suites: [Suite]
    /// `xi:include` targets (usually `file:///System/Library/ScriptingDefinitions/...`).
    public var includes: [String]

    public init(title: String = "", suites: [Suite] = [], includes: [String] = []) {
        self.title = title
        self.suites = suites
        self.includes = includes
    }

    public struct Suite: Sendable, Equatable {
        public var name: String
        public var description: String
        public var classes: [ClassEntry] = []
        public var commands: [Command] = []
        public var enumerations: [Enumeration] = []
    }

    /// A class, a class extension (`extends`) or a record type.
    public struct ClassEntry: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case classDefinition, classExtension, recordType
        }

        public var kind: Kind
        public var name: String
        public var description: String
        public var plural: String?
        public var inherits: String?
        public var properties: [Property] = []
        public var elements: [String] = []
        public var respondsTo: [String] = []
    }

    public struct Property: Sendable, Equatable {
        public var name: String
        public var type: String
        public var description: String
        public var readOnly: Bool
    }

    public struct Command: Sendable, Equatable {
        public var name: String
        public var description: String
        public var directParameter: Parameter?
        public var parameters: [Parameter] = []
        public var result: String?
    }

    public struct Parameter: Sendable, Equatable {
        public var name: String
        public var type: String
        public var description: String
        public var optional: Bool
    }

    public struct Enumeration: Sendable, Equatable {
        public var name: String
        public var values: [String]
    }

    public var isEmpty: Bool {
        suites.allSatisfy { $0.classes.isEmpty && $0.commands.isEmpty && $0.enumerations.isEmpty }
    }

    /// Adds the suites of an included dictionary that this one does not have yet.
    public mutating func merge(_ other: SdefDictionary) {
        let known = Set(suites.map(\.name))
        suites += other.suites.filter { !known.contains($0.name) }
    }
}

// MARK: - Parsing

extension SdefDictionary {
    /// Parses sdef XML (as printed by `/usr/bin/sdef`). Throws if the XML is malformed.
    public static func parse(_ data: Data) throws -> SdefDictionary {
        let parser = XMLParser(data: data)
        let delegate = SdefParserDelegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "unknown error"
            throw SdefError.malformed(message)
        }
        return delegate.dictionary
    }
}

public enum SdefError: LocalizedError, Equatable {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let message): "The scripting dictionary could not be read: \(message)"
        }
    }
}

/// Builds an `SdefDictionary` from XMLParser events. Descriptions come from attributes;
/// `<documentation>` bodies are ignored.
/// `@unchecked Sendable`: one parser uses it synchronously, on one thread, then it is dropped.
private final class SdefParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    var dictionary = SdefDictionary()
    private var suite: SdefDictionary.Suite?
    private var classEntry: SdefDictionary.ClassEntry?
    private var property: SdefDictionary.Property?
    private var command: SdefDictionary.Command?
    private var parameter: SdefDictionary.Parameter?
    private var parameterIsDirect = false
    private var resultType: String?
    private var enumeration: SdefDictionary.Enumeration?
    /// Child `<type>` elements of the current property, parameter or result.
    private var childTypes: [String] = []
    /// Depth inside a hidden element whose contents are skipped.
    private var skipDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        if skipDepth > 0 {
            skipDepth += 1
            return
        }
        if attributes["hidden"] == "yes" || elementName == "event" {
            skipDepth = 1
            return
        }
        start(elementName, attributes)
    }

    private func start(_ element: String, _ attributes: [String: String]) {
        let name = attributes["name"] ?? ""
        let description = attributes["description"] ?? ""
        switch element {
        case "dictionary":
            dictionary.title = attributes["title"] ?? dictionary.title
        case "suite":
            suite = SdefDictionary.Suite(name: name, description: description)
        case "class", "class-extension", "record-type":
            startClass(element, attributes)
        case "property":
            property = SdefDictionary.Property(
                name: name, type: attributes["type"] ?? "", description: description,
                readOnly: attributes["access"] == "r"
            )
            childTypes = []
        case "element":
            if let type = attributes["type"] { classEntry?.elements.append(type) }
        case "responds-to":
            if let target = attributes["command"] ?? attributes["name"] { classEntry?.respondsTo.append(target) }
        case "command":
            command = SdefDictionary.Command(name: name, description: description)
        case "direct-parameter", "parameter":
            startParameter(element, attributes)
        case "result":
            resultType = attributes["type"]
            childTypes = []
        case "type":
            if let type = attributes["type"] {
                childTypes.append(attributes["list"] == "yes" ? "list of \(type)" : type)
            }
        case "enumeration":
            enumeration = SdefDictionary.Enumeration(name: name, values: [])
        case "enumerator":
            enumeration?.values.append(name)
        case "xi:include", "include":
            if let href = attributes["href"] { dictionary.includes.append(href) }
        default:
            break
        }
    }

    private func startClass(_ element: String, _ attributes: [String: String]) {
        let kind: SdefDictionary.ClassEntry.Kind
        switch element {
        case "class": kind = .classDefinition
        case "record-type": kind = .recordType
        default: kind = .classExtension
        }
        let name = attributes["name"] ?? ""
        classEntry = SdefDictionary.ClassEntry(
            kind: kind,
            name: kind == .classExtension ? attributes["extends"] ?? name : name,
            description: attributes["description"] ?? "",
            plural: attributes["plural"],
            inherits: attributes["inherits"]
        )
    }

    private func startParameter(_ element: String, _ attributes: [String: String]) {
        parameterIsDirect = element == "direct-parameter"
        parameter = SdefDictionary.Parameter(
            name: parameterIsDirect ? "direct parameter" : attributes["name"] ?? "",
            type: attributes["type"] ?? "",
            description: attributes["description"] ?? "",
            optional: attributes["optional"] == "yes"
        )
        childTypes = []
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        end(elementName)
    }

    private func resolvedType(_ declared: String) -> String {
        if !declared.isEmpty { return declared }
        return childTypes.isEmpty ? "any" : childTypes.joined(separator: " or ")
    }

    private func end(_ element: String) {
        switch element {
        case "suite":
            if let suite { dictionary.suites.append(suite) }
            suite = nil
        case "class", "class-extension", "record-type":
            if let classEntry { suite?.classes.append(classEntry) }
            classEntry = nil
        case "property":
            if var property {
                property.type = resolvedType(property.type)
                classEntry?.properties.append(property)
            }
            property = nil
        case "command":
            if let command { suite?.commands.append(command) }
            command = nil
        case "direct-parameter", "parameter":
            if var parameter {
                parameter.type = resolvedType(parameter.type)
                if parameterIsDirect {
                    command?.directParameter = parameter
                } else {
                    command?.parameters.append(parameter)
                }
            }
            parameter = nil
        case "result":
            command?.result = resolvedType(resultType ?? "")
        case "enumeration":
            if let enumeration { suite?.enumerations.append(enumeration) }
            enumeration = nil
        default:
            break
        }
    }
}
