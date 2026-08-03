// The test target carries its own copy of the language-mode guard in
// `Sources/Core/Concurrency/LanguageMode.swift`, because it is compiled
// separately and with its own `swiftSettings`. A test target left in Swift 5
// mode is the worse of the two failures: the library would still reject
// isolation violations, but every test exercising an actor hop or a `Sendable`
// boundary would be checked under the rules the library does not use, so the
// suite would stop being evidence about how the shipped code behaves.
//
// See the source-side file for why `#if swift(...)` is the right spelling here.

#if !swift(>=6.0)
#error("""
ViewModelTests must be compiled in the Swift 6 language mode, matching the \
library it tests. Restore `.swiftLanguageMode(.v6)` on the test target in \
Package.swift.
""")
#endif
