//
// Regenerates this package from the patched SVDs produced by
// `Tools/extract-svd.rb`.
//
// For every `svd/<id>.svd.patched` it writes a device target:
//
//     - Sources/<ID>/<id>.svd        the patched SVD, renamed so the plugin's
//                                    `fileExtension("svd")` match succeeds
//
//     - Sources/<ID>/svd2swift.json  the peripheral list SVD2SwiftPlugin needs
//
//     - Sources/<ID>/device.json     core, FPU and interrupt numbers, for
//                                    startup runtimes such as swift-cortex-m-rt
//
//     - Sources/<ID>/Exports.swift   `@_exported import MMIO`
//
// then rewrites the device list in `Package.swift`.
//

import Foundation
import SVD

#if canImport(FoundationXML)
    import FoundationXML
#endif

@main
struct Generate {
    static let patchedSVDSuffix = ".svd.patched"
    static let beginMarker = "// BEGIN GENERATED DEVICES"
    static let endMarker = "// END GENERATED DEVICES"

    /// The package root, derived from this file's location at compile time
    /// (`<root>/Tools/Generate/Generate.swift`), falling back to the working
    /// directory if the tool was built from a checkout that has since moved.
    static let packageDirectory: URL = {
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Generate/
            .deletingLastPathComponent()  // Tools/
            .deletingLastPathComponent()  // <root>

        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )

        for candidate in [fromSource, workingDirectory] {
            let manifest = candidate.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: manifest.path) { return candidate }
        }

        fail("could not locate the package root; run this from the package directory")
    }()

    static var svdDirectory: URL { packageDirectory.appendingPathComponent("svd") }
    static var sourcesDirectory: URL { packageDirectory.appendingPathComponent("Sources") }
    static var manifestFile: URL { packageDirectory.appendingPathComponent("Package.swift") }

    /// Devices left out because their registers cannot be represented.
    static let excludedDevices: Set<String> = []

    struct DeviceResult: Sendable {
        var written: Int
        var unresolvedEnumerations: Int
    }

    static func main() async throws {
        let deviceIDs = try discoverDeviceIDs()
            .filter { !excludedDevices.contains($0) }

        var written = 0
        var unresolvedEnumerations = 0

        try await withThrowingTaskGroup(of: DeviceResult.self) { group in
            var pending = deviceIDs.makeIterator()

            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                guard let id = pending.next() else { break }
                group.addTask { try generate(device: id) }
            }

            while let result = try await group.next() {
                written += result.written
                unresolvedEnumerations += result.unresolvedEnumerations

                if let id = pending.next() {
                    group.addTask { try generate(device: id) }
                }
            }
        }

        let pruned = try prune(keeping: Set(deviceIDs.map { $0.uppercased() }))
        let manifestUpdated = try updateManifest(deviceIDs: deviceIDs)

        let unresolvedWarning =
            unresolvedEnumerations > 0
            ? "\nwarning: \(unresolvedEnumerations) shared enumeration(s) did not resolve" : ""

        print(
            """
            \(deviceIDs.count) devices, \(written) file(s) written\
            \(pruned > 0 ? ", \(pruned) stale target(s) removed" : "")\
            \(manifestUpdated ? ", Package.swift updated" : "")
            \(excludedDevices.count) device(s) are currently excluded\
            \(unresolvedWarning)
            """
        )
    }

    // MARK: - Steps

    /// Writes the three files making up one device target.
    static func generate(device id: String) throws -> DeviceResult {
        let target = sourcesDirectory.appendingPathComponent(id.uppercased())

        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
        )

        let patched = try Data(
            contentsOf: svdDirectory.appendingPathComponent(id + patchedSVDSuffix)
        )

        let flattened = try DerivedFromFlattener.flatten(patched, device: id)
        let svd = flattened.data

        // Peripheral names come from the SVD as shipped, so the list can't
        // disagree with what SVD2Swift sees.
        let device = try SVDDevice(data: svd)
        let peripherals = Set(device.peripherals.peripheral.map(\.name)).sorted()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let configuration = try encoder.encode(
            Configuration(peripherals: peripherals)
        )

        let deviceInfo = try encoder.encode(
            DeviceInfo(device: device, id: id)
        )

        var written = 0

        if write(svd, to: target.appendingPathComponent("\(id).svd")) {
            written += 1
        }

        if write(configuration, to: target.appendingPathComponent("svd2swift.json")) {
            written += 1
        }

        if write(deviceInfo, to: target.appendingPathComponent("device.json")) {
            written += 1
        }

        if write(exports(for: id), to: target.appendingPathComponent("Exports.swift")) {
            written += 1
        }

        return DeviceResult(
            written: written,
            unresolvedEnumerations: flattened.unresolvedEnumerations,
        )
    }

    static func discoverDeviceIDs() throws -> [String] {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: svdDirectory.path
            )
        else {
            fail("no 'svd' directory; run ./Tools/extract-svd.rb first")
        }

        let ids =
            contents
            .filter { $0.hasSuffix(patchedSVDSuffix) }
            .map { String($0.dropLast(patchedSVDSuffix.count)) }
            .sorted()

        guard !ids.isEmpty else {
            fail("no *\(patchedSVDSuffix) files in 'svd'; run ./Tools/extract-svd.rb first")
        }

        return ids
    }

    static func exports(for id: String) -> Data {
        Data(
            """
            //
            // Peripheral access target for \(id.uppercased()), use `import \(id.uppercased())`.
            //

            @_exported import MMIO

            """.utf8
        )
    }

    /// Removes `Sources/` entries no longer backed by an SVD, so dropping a
    /// device from `svd/` drops its target too.
    static func prune(keeping moduleNames: Set<String>) throws -> Int {
        let contents =
            (try? FileManager.default.contentsOfDirectory(atPath: sourcesDirectory.path))
            ?? []

        var removed = 0
        for entry in contents

        where !entry.hasPrefix(".") && !moduleNames.contains(entry) {
            try FileManager.default.removeItem(at: sourcesDirectory.appendingPathComponent(entry))
            removed += 1
        }

        return removed
    }

    static func updateManifest(deviceIDs: [String]) throws -> Bool {
        let manifest = try String(contentsOf: manifestFile, encoding: .utf8)

        guard
            let begin = manifest.range(of: beginMarker),
            let end = manifest.range(of: endMarker),
            begin.upperBound <= end.lowerBound
        else {
            fail("Package.swift is missing the '\(beginMarker)' / '\(endMarker)' markers")
        }

        let list =
            deviceIDs
            .map { String(repeating: " ", count: 4) + "\"\($0)\",\n" }
            .joined()

        var updated = manifest

        updated.replaceSubrange(
            begin.upperBound..<end.lowerBound,
            with: "\nlet deviceIDs: [String] = [\n\(list)]\n",
        )

        return write(Data(updated.utf8), to: manifestFile)
    }

    // MARK: - Helpers

    /// Writes only when the contents would actually change
    static func write(_ data: Data, to url: URL) -> Bool {
        if let existing = try? Data(contentsOf: url), existing == data { return false }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            fail("could not write \(url.path): \(error)")
        }

        return true
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

extension Generate {
    /// The subset of `svd2swift.json` this package writes.
    struct Configuration: Encodable {
        var accessLevel = "public"
        var peripherals: [String]

        enum CodingKeys: String, CodingKey {
            case accessLevel = "access-level"
            case peripherals = "peripherals"
        }
    }

    /// The facts a startup runtime needs and cannot get from the generated code
    struct DeviceInfo: Encodable {
        var cpu: String
        var fpuPresent: Bool
        var fpuDP: Bool?
        var interrupts: [String: UInt64]

        init(device: SVDDevice, id: String) {
            guard let cpu = device.cpu else {
                fail("\(id): the SVD has no <cpu> element")
            }

            var interrupts: [String: UInt64] = [:]

            for peripheral in device.peripherals.peripheral {
                guard let peripheralInterrupt = peripheral.interrupt else {
                    continue
                }

                for interrupt in peripheralInterrupt {
                    let (name, value) = (interrupt.name, interrupt.value)

                    if let existing = interrupts[name], existing != value {
                        fail("\(id): interrupt \(name) is both \(existing) and \(value)")
                    }

                    interrupts[name] = value
                }
            }

            self.cpu = cpu.name.description
            self.fpuPresent = cpu.fpuPresent
            self.fpuDP = cpu.fpuDP
            self.interrupts = interrupts
        }
    }
}
