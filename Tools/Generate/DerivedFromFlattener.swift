//
// Resolves CMSIS-SVD's fully-qualified `derivedFrom` references so swift-mmio
// can consume the input SVDs.
//
// `derivedFrom` may name either a sibling ("AFRL") or a full path into the
// device ("GPIOA.AFRL.AFSEL%s"). swift-mmio now only implements the first
// form - `Array.deriveElements()` looks the parent up in a map keyed by the
// names of the deriving element's siblings - so every qualified reference is
// rejected as an unknown item. The fix is to do what `derivedFrom` means: copy
// across every child the deriving element does not already define for itself,
// then drop the attribute. Sibling references are left for swift-mmio to resolve.
//
// Every qualified path in these SVDs is absolute, starting at a peripheral, in
// one of five shapes:
//
//     cluster    P.C
//     register   P.R
//     register   P.C.R
//     field      P.R.F
//     field      P.C.R.F
//

import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

final class DerivedFromFlattener {
    struct Output {
        var data: Data

        /// Shared enumerations whose `derivedFrom` target was not found. These lose
        /// their projections, exactly as they do without this pass, so they are
        /// reported rather than treated as fatal.
        var unresolvedEnumerations: Int
    }

    /// Rewrites `data` into the form swift-mmio can consume.
    static func flatten(_ data: Data, device id: String) throws -> Output {
        let document = try XMLDocument(
            data: data,
            options: [
                .nodePreserveWhitespace,
                .nodePreserveCDATA,
            ],
        )

        guard let root = document.rootElement() else {
            throw Failure("\(id): SVD has no root element")
        }

        let flattener = DerivedFromFlattener(root: root, id: id)
        try flattener.flattenQualifiedReferences()
        try flattener.resolveEnumerations()
        try flattener.validateFieldLayout()

        return Output(
            data: document.xmlData,
            unresolvedEnumerations: flattener.unresolvedEnumerations,
        )
    }

    private struct ChildKey: Hashable {
        var container: ObjectIdentifier
        var kind: String
    }

    private let root: XMLElement
    private let id: String
    private var peripheralsByName: [String: XMLElement] = [:]
    private var childCache: [ChildKey: [String: XMLElement]] = [:]
    private var resolved: Set<ObjectIdentifier> = []
    private var resolving: Set<ObjectIdentifier> = []
    private var unresolvedEnumerations = 0

    private init(root: XMLElement, id: String) {
        self.root = root
        self.id = id

        for peripherals in root.elements(forName: "peripherals") {
            for peripheral in peripherals.elements(forName: "peripheral") {
                if let name = Self.name(of: peripheral) {
                    peripheralsByName[name] = peripheral
                }
            }
        }
    }

    /// Repeats until no qualified reference is left. One pass is not enough:
    /// inlining a register copies its fields, and those copies are fresh nodes
    /// that may carry qualified references of their own, so each pass can uncover
    /// work for the next. Chains are shallow, so this settles in a few rounds.
    private func flattenQualifiedReferences() throws {
        for pass in 1... {
            let derived = try root.nodes(forXPath: "//*[@derivedFrom]")
                .compactMap { $0 as? XMLElement }
                .filter { $0.attribute(forName: "derivedFrom")?.stringValue?.contains(".") == true }

            if derived.isEmpty {
                return
            }

            guard pass <= 16 else {
                throw Failure(
                    "\(id): qualified derivedFrom did not settle after \(pass - 1) passes"
                )
            }

            for element in derived {
                try resolve(element)
            }
        }
    }

    private func resolve(_ element: XMLElement) throws {
        let identity = ObjectIdentifier(element)

        if resolved.contains(identity) {
            return
        }

        guard resolving.insert(identity).inserted else {
            throw Failure("\(id): cyclic derivedFrom at \(describe(element))")
        }

        defer {
            resolving.remove(identity)
            resolved.insert(identity)
        }

        guard
            let reference = element.attribute(forName: "derivedFrom")?.stringValue,
            reference.contains(".")
        else {
            return  // A sibling reference; swift-mmio handles these.
        }

        guard let source = locate(reference, kind: element.name ?? "") else {
            throw Failure(
                "\(id): \(describe(element)) derives from '\(reference)', which does not resolve"
            )
        }

        guard source !== element else {
            throw Failure("\(id): \(describe(element)) derives from itself via '\(reference)'")
        }

        // The source may derive from something itself, so complete it first.
        try resolve(source)
        merge(source, into: element)

        element.removeAttribute(forName: "derivedFrom")
    }

    // MARK: - Enumerations

    /// SVD shares one enumeration across several fields of a peripheral by
    /// naming it and pointing the rest at it with `derivedFrom`. swift-mmio
    /// implements neither half of that:
    ///
    ///   - `SVDEnumeration` is not `SVDDerivable` and `SVDDevice.inflate()` never
    ///     derives enumerations, so a referencing enumeration stays empty -
    ///     and `SVD+Export.enumeration()` drops empty ones. Those fields silently
    ///     lose their projections. Inlining the values back restores them.
    ///
    ///   - An enumeration is named after its `<name>` and re-emitted for every
    ///     field that uses it, so a shared name becomes N identical structs in one
    ///     extension scope. Dropping `<name>` falls back to `<Field>Values`,
    ///     which is unique because field names are unique within a register.
    ///
    /// References resolve within their own peripheral - across these SVDs, every
    /// one of them does.
    private func resolveEnumerations() throws {
        for peripherals in root.elements(forName: "peripherals") {
            for peripheral in peripherals.elements(forName: "peripheral") {
                let enumerations =
                    try peripheral.nodes(forXPath: ".//enumeratedValues")
                    .compactMap { $0 as? XMLElement }

                var byName: [String: XMLElement] = [:]
                for enumeration in enumerations

                where !enumeration.elements(forName: "enumeratedValue").isEmpty {
                    if let name = Self.name(of: enumeration), byName[name] == nil {
                        byName[name] = enumeration
                    }
                }

                for enumeration in enumerations {
                    guard
                        let reference =
                            enumeration
                            .attribute(forName: "derivedFrom")?
                            .stringValue
                    else { continue }

                    enumeration.removeAttribute(forName: "derivedFrom")

                    // A reference that already carries its own values needs nothing.
                    guard enumeration.elements(forName: "enumeratedValue").isEmpty else { continue }

                    guard let key = reference.split(separator: ".").last.map(String.init),
                        let source = byName[key], source !== enumeration
                    else {
                        unresolvedEnumerations += 1
                        continue
                    }

                    merge(source, into: enumeration)
                }
            }
        }

        // Last, because the index above is keyed on these names.
        for node in try root.nodes(forXPath: "//enumeratedValues") {
            guard let enumeration = node as? XMLElement else { continue }

            for name in enumeration.elements(forName: "name").reversed() {
                enumeration.removeChild(at: name.index)
            }
        }
    }

    // MARK: - Validation

    /// Fails if any register's fields overlap.
    ///
    /// swift-mmio's `@Register` requires a register's fields to partition it,
    /// while svd2rust is happy to let them overlap -- so stm32-rs models a few
    /// registers in a way that cannot be expressed here. Those are corrected in
    /// `Tools/patches`, and this is the check that keeps that set honest: a
    /// future stm32-rs bump introducing a fifth one stops generation with a
    /// precise message, rather than surfacing as a macro error partway through
    /// a very long build.
    ///
    /// Only fields a register declares itself are checked. One that derives them
    /// carries none of its own, and the register it derives from is checked in
    /// its place.
    ///
    /// Bit ranges running past the end of a register are deliberately not
    /// checked: that needs the register-size inheritance swift-mmio itself
    /// applies, and reimplementing it here would risk disagreeing with it.
    private func validateFieldLayout() throws {
        for peripherals in root.elements(forName: "peripherals") {
            for peripheral in peripherals.elements(forName: "peripheral") {
                let peripheralName = Self.name(of: peripheral) ?? "?"

                for node in try peripheral.nodes(forXPath: ".//register") {
                    guard let register = node as? XMLElement else { continue }

                    var spans: [(low: Int, high: Int, name: String)] = []
                    for fields in register.elements(forName: "fields") {
                        for field in fields.elements(forName: "field") {
                            spans.append(contentsOf: Self.spans(of: field))
                        }
                    }
                    spans.sort { $0.low < $1.low }

                    for (previous, next) in zip(spans, spans.dropFirst())
                    where next.low < previous.high && previous.name != next.name {
                        throw Failure(
                            """
                            \(id): \(peripheralName).\(Self.name(of: register) ?? "?") has \
                            overlapping fields, which cannot be represented -- \
                            \(previous.name) \(previous.low)..<\(previous.high) and \
                            \(next.name) \(next.low)..<\(next.high). \
                            Correct it in Tools/patches, as the others are.
                            """)
                    }
                }
            }
        }
    }

    /// The bit ranges a field occupies, one per element if it is an array.
    private static func spans(
        of field: XMLElement
    ) -> [(low: Int, high: Int, name: String)] {
        func value(_ name: String) -> Int? {
            guard let text = field.elements(forName: name).first?.stringValue else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X")
                ? Int(trimmed.dropFirst(2), radix: 16)
                : Int(trimmed)
        }

        guard let offset = value("bitOffset"), let width = value("bitWidth"),
            let name = name(of: field)
        else { return [] }

        guard let count = value("dim"), let stride = value("dimIncrement") else {
            return [(offset, offset + width, name)]
        }
        return (0..<count).map {
            (offset + $0 * stride, offset + $0 * stride + width, name)
        }
    }

    // MARK: - Lookup

    private func locate(_ reference: String, kind: String) -> XMLElement? {
        var path = reference.split(separator: ".").map(String.init)[...]

        guard
            let peripheralName = path.popFirst(),
            let peripheral = peripheralsByName[peripheralName],
            let leafName = path.popLast()
        else {
            return nil
        }

        // Whatever sits between the peripheral and the leaf names a cluster, except
        // for a field, whose immediately preceding component names its register.
        var scopes = registerScopes(of: peripheral)
        let registerName = kind == "field" ? path.popLast() : nil

        for clusterName in path {
            guard
                let cluster = child(clusterName, kind: "cluster", in: scopes)
            else {
                return nil
            }

            scopes = [cluster]
        }

        if let registerName {
            guard
                let register = child(registerName, kind: "register", in: scopes)
            else {
                return nil
            }

            return fields(of: register)[leafName]
        }

        return child(leafName, kind: kind, in: scopes)
    }

    /// The containers a peripheral's top-level registers and clusters live in,
    /// following its own `derivedFrom` chain - a qualified path may point into a
    /// peripheral that only derives its register map.
    private func registerScopes(of peripheral: XMLElement) -> [XMLElement] {
        var scopes: [XMLElement] = []
        var seen: Set<ObjectIdentifier> = []
        var current: XMLElement? = peripheral

        while let peripheral = current, seen.insert(ObjectIdentifier(peripheral)).inserted {
            scopes.append(contentsOf: peripheral.elements(forName: "registers"))
            let base = peripheral.attribute(forName: "derivedFrom")?.stringValue

            current = base.flatMap { $0.contains(".") ? nil : peripheralsByName[$0] }
        }

        return scopes
    }

    /// Searches the given containers, then their nested clusters breadth-first,
    /// so a name defined directly in scope wins over one nested deeper.
    private func child(_ name: String, kind: String, in containers: [XMLElement]) -> XMLElement? {
        var frontier = containers
        var seen = Set(containers.map(ObjectIdentifier.init))

        while !frontier.isEmpty {
            for container in frontier {
                if let match = index(of: container, kind: kind)[name] {
                    return match
                }
            }

            frontier = frontier.flatMap { container in
                index(of: container, kind: "cluster").values.filter {
                    seen.insert(ObjectIdentifier($0)).inserted
                }
            }
        }

        return nil
    }

    private func index(of container: XMLElement, kind: String) -> [String: XMLElement] {
        let key = ChildKey(container: ObjectIdentifier(container), kind: kind)
        if let cached = childCache[key] { return cached }

        var result: [String: XMLElement] = [:]

        for child in container.elements(forName: kind) {
            if let name = Self.name(of: child) { result[name] = child }
        }

        childCache[key] = result

        return result
    }

    private func fields(of register: XMLElement) -> [String: XMLElement] {
        var result: [String: XMLElement] = [:]

        // A register may in turn derive its fields from a sibling register.
        if let base = register.attribute(forName: "derivedFrom")?.stringValue,
            !base.contains("."),
            let parent = register.parent as? XMLElement,
            let source = index(of: parent, kind: "register")[base],
            source !== register
        {
            result = fields(of: source)
        }

        for fields in register.elements(forName: "fields") {
            for field in fields.elements(forName: "field") {
                if let name = Self.name(of: field) { result[name] = field }
            }
        }

        return result
    }

    // MARK: - Merge

    /// Array shape, which is deliberately *not* inherited. See `merge`.
    private static let dimensionTags: Set<String> = [
        "dim", "dimIncrement", "dimIndex", "dimName", "dimArrayIndex",
    ]

    /// Copies across every child the deriving element does not already define.
    /// SVD inheritance is per-property and a property is a child element, so a
    /// locally present tag always wins.
    private func merge(_ source: XMLElement, into destination: XMLElement) {
        let defined = Set(
            (destination.children ?? []).compactMap { ($0 as? XMLElement)?.name }
        )

        let destinationIsArray = Self.name(of: destination)?.contains("%s") ?? false

        var changedContainers = false

        for child in source.children ?? [] {
            guard
                let element = child as? XMLElement,
                let name = element.name,
                !defined.contains(name),
                destinationIsArray || !Self.dimensionTags.contains(name)
            else {
                continue
            }

            guard let copy = element.copy() as? XMLNode else { continue }
            destination.addChild(copy)
            changedContainers = changedContainers || name == "registers"
        }

        // Inheriting a register map changes what the destination contains, so
        // indexes built from it are stale.
        if changedContainers {
            childCache.removeAll()
        }
    }

    // MARK: - Helpers

    private static func name(of element: XMLElement) -> String? {
        element
            .elements(forName: "name").first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func describe(_ element: XMLElement) -> String {
        "\(element.name ?? "element") '\(Self.name(of: element) ?? "?")'"
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
