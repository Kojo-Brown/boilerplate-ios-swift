// Phase 0 item 4: the Swift 6 language mode is a build-time fact, not a claim.
//
// `Package.swift` sets `.swiftLanguageMode(.v6)` on this target, and Swift 6
// mode is what turns strict concurrency checking from a set of warnings into
// errors — data races across an isolation boundary stop compiling instead of
// being reported and ignored. That setting is one line in a manifest, though,
// and nothing failed if it were dropped, downgraded to `.v5`, or overridden by
// a `SWIFT_VERSION` build setting on the xcodebuild command line. The package
// would simply go back to compiling under Swift 5 rules and the concurrency
// diagnostics this repo exists to demonstrate would quietly become advisory.
//
// `#if swift(...)` tests the *language mode* (`-swift-version`), not the
// compiler that implements it — `#if compiler(...)` is the one that reports the
// toolchain. So this is the direct check, and it fails at compile time in the
// target it protects rather than in a CI script that could be skipped.

#if !swift(>=6.0)
#error("""
BoilerplateiOSSwift must be compiled in the Swift 6 language mode. \
Strict concurrency checking is only complete-by-default there; under Swift 5 \
the isolation violations this package is written to reject downgrade to \
warnings. Restore `.swiftLanguageMode(.v6)` on this target in Package.swift, \
and check that no SWIFT_VERSION build setting is overriding it.
""")
#endif
