// The same guard `Tests/ViewModelTests/LanguageMode.swift` carries, for the
// same reason: this target is compiled separately, with its own
// `swiftSettings`, and a test target left in Swift 5 mode would be checked
// under rules the library it renders does not use.

#if !swift(>=6.0)
#error("""
SnapshotTests must be compiled in the Swift 6 language mode, matching the \
library it renders. Restore `.swiftLanguageMode(.v6)` on the test target in \
Package.swift.
""")
#endif
