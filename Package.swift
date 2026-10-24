// swift-tools-version: 6.4

import PackageDescription

// BEGIN GENERATED DEVICES
let deviceIDs: [String] = [
    "stm32c011",
    "stm32c031",
    "stm32c051",
    "stm32c071",
    "stm32c091",
    "stm32c092",
    "stm32f0x0",
    "stm32f0x1",
    "stm32f0x2",
    "stm32f0x8",
    "stm32f100",
    "stm32f101",
    "stm32f102",
    "stm32f103",
    "stm32f107",
    "stm32f215",
    "stm32f217",
    "stm32f301",
    "stm32f302",
    "stm32f303",
    "stm32f373",
    "stm32f3x4",
    "stm32f401",
    "stm32f405",
    "stm32f407",
    "stm32f410",
    "stm32f411",
    "stm32f412",
    "stm32f413",
    "stm32f415",
    "stm32f417",
    "stm32f427",
    "stm32f429",
    "stm32f437",
    "stm32f439",
    "stm32f446",
    "stm32f469",
    "stm32f722",
    "stm32f723",
    "stm32f730",
    "stm32f732",
    "stm32f733",
    "stm32f745",
    "stm32f746",
    "stm32f750",
    "stm32f756",
    "stm32f765",
    "stm32f767",
    "stm32f769",
    "stm32f777",
    "stm32f778",
    "stm32f779",
    "stm32g030",
    "stm32g031",
    "stm32g041",
    "stm32g050",
    "stm32g051",
    "stm32g061",
    "stm32g070",
    "stm32g071",
    "stm32g081",
    "stm32g0b0",
    "stm32g0b1",
    "stm32g0c1",
    "stm32g431",
    "stm32g441",
    "stm32g471",
    "stm32g473",
    "stm32g474",
    "stm32g483",
    "stm32g484",
    "stm32g491",
    "stm32g4a1",
    "stm32h503",
    "stm32h523",
    "stm32h533",
    "stm32h562",
    "stm32h563",
    "stm32h573",
    "stm32h723",
    "stm32h725",
    "stm32h730",
    "stm32h733",
    "stm32h735",
    "stm32h742",
    "stm32h743",
    "stm32h743v",
    "stm32h745cm4",
    "stm32h745cm7",
    "stm32h747cm4",
    "stm32h747cm7",
    "stm32h750",
    "stm32h753",
    "stm32h753v",
    "stm32h755cm4",
    "stm32h755cm7",
    "stm32h757cm4",
    "stm32h757cm7",
    "stm32h7a3",
    "stm32h7b0",
    "stm32h7b3",
    "stm32h7r",
    "stm32h7s",
    "stm32l0x0",
    "stm32l0x1",
    "stm32l0x2",
    "stm32l0x3",
    "stm32l100",
    "stm32l151",
    "stm32l152",
    "stm32l162",
    "stm32l412",
    "stm32l4p5",
    "stm32l4r5",
    "stm32l4r9",
    "stm32l4x1",
    "stm32l4x2",
    "stm32l4x3",
    "stm32l4x5",
    "stm32l4x6",
    "stm32l552",
    "stm32l562",
    "stm32mp153",
    "stm32mp157",
    "stm32n645",
    "stm32n647",
    "stm32n655",
    "stm32n657",
    "stm32u031",
    "stm32u073",
    "stm32u083",
    "stm32u535",
    "stm32u545",
    "stm32u575",
    "stm32u585",
    "stm32u595",
    "stm32u599",
    "stm32u5a5",
    "stm32u5a9",
    "stm32wb05",
    "stm32wb06",
    "stm32wb07",
    "stm32wb09",
    "stm32wb55",
    "stm32wba50",
    "stm32wba52",
    "stm32wba54",
    "stm32wba55",
    "stm32wl33",
    "stm32wl5x_cm0p",
    "stm32wl5x_cm4",
    "stm32wle5",
]
// END GENERATED DEVICES

struct Config {
    static let packageName: String = "swift-stm32"
    static let devicesEnv: String = "SWIFT_STM32_DEVICES"
}

let selectedDeviceIDs: [String] = {
    guard let requested = Context.environment[Config.devicesEnv] else {
        fatalError(
            """
            \(Config.packageName) no devices selected.

            Set \(Config.devicesEnv) to the device(s) you need, for example:

                \(Config.devicesEnv)=STM32G431 swift build

            Use \(Config.devicesEnv)=all to select every supported device.
            """
        )
    }

    let names =
        requested
        .split(separator: ",")
        .map { String($0).lowercased().filter { !$0.isWhitespace } }
        .filter { !$0.isEmpty }

    if names.contains("all") {
        return deviceIDs
    }

    let unknown = names.filter { !deviceIDs.contains($0) }

    if !unknown.isEmpty {
        let error = "\(Config.packageName) unknown device(s) in \(Config.devicesEnv):"
        fatalError(error + " " + unknown.joined(separator: ", "))
    }

    return deviceIDs.filter { names.contains($0) }
}()

let package = Package(
    name: Config.packageName,
    products: selectedDeviceIDs.map { id in
        .library(name: id.uppercased(), targets: [id.uppercased()])
    },
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-mmio",
            revision: "b43b13d5acab79f099860c52e0e5dbd72bfe81e3"
        ),
    ],
    targets: selectedDeviceIDs.map { id in
        .target(
            name: id.uppercased(),
            dependencies: [.product(name: "MMIO", package: "swift-mmio")],
            exclude: ["device.json"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [.plugin(name: "SVD2SwiftPlugin", package: "swift-mmio")],
        )
    } + [
        .executableTarget(
            name: "Generate",
            dependencies: [.product(name: "SVD", package: "swift-mmio")],
            path: "Tools/Generate",
        )
    ],
)
