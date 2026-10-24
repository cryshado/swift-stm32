# swift-stm32

Embedded Swift peripheral access targets for STM32 microcontrollers, built on [apple/swift-mmio](https://github.com/apple/swift-mmio).

It currently uses patched SVD files provided by [stm32-rs](https://github.com/stm32-rs/stm32-rs), but these patches introduce some compatibility issues with [apple/swift-mmio](https://github.com/apple/swift-mmio), because of that we have own subset of minor patches located in [./Tools/patches](./Tools/patches) to fix such issues. Original unpatched SVD files may not be used because they may have errors and inconsistencies, that's why [stm32-rs](https://github.com/stm32-rs/stm32-rs) maintains patches in the first place.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

SVD files under `Sources/**/*.svd` originate from STMicroelectronics, are subject to ST's terms, licenses, conditions and are not covered by the Apache-2.0/MIT dual license above. You can find more details in [`./notices/ST_README.md`](./notices/ST_README.md) and [`./notices/ST_SLA.pdf`](./notices/ST_SLA.pdf).

## Disclaimer

This project is an independently developed open-source package and is not affiliated with, sponsored by, or endorsed by STMicroelectronics or Apple Inc. STM32 is a trademark of STMicroelectronics International NV or its affiliates. Swift is a trademark of Apple Inc., registered in the U.S. and other countries and regions.

## Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
