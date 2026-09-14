import Foundation

// Stand-in for XCTest, which the Command Line Tools toolchain doesn't ship.
// Single-threaded by construction: checks run top-to-bottom from main.swift.
private nonisolated(unsafe) var failures: [String] = []

func expect(_ condition: Bool, _ label: String, file: StaticString = #fileID, line: UInt = #line) {
    if !condition { failures.append("\(file):\(line) — \(label)") }
}

func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ label: String,
    file: StaticString = #fileID, line: UInt = #line
) {
    expect(actual == expected, "\(label): expected \(expected), got \(actual)", file: file, line: line)
}

func finish() -> Never {
    guard failures.isEmpty else {
        failures.forEach { print("✗ \($0)") }
        print("\(failures.count) failure(s)")
        exit(1)
    }
    print("✓ all checks passed")
    exit(0)
}
