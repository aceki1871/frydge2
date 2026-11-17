//
//  DebugLogging.swift
//  FrydgeRecipes
//
//  Module-wide shadow of `Swift.print`.
//
//  The app has several hundred diagnostic `print(...)` calls, many of which
//  run in hot paths (view bodies, CloudKit refresh loops) and some of which
//  include record IDs, list names or sync payloads. Shadowing `print` at
//  module scope keeps all of that in Debug builds and compiles it out of
//  Release, so production builds pay nothing for logging and never write
//  user data to the system console.
//

import Foundation

@inline(__always)
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    let output = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(output, terminator: terminator)
    #endif
}
