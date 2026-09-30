import Testing

func expectTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let actual = try value(); #expect(actual, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let actual = try value(); #expect(!actual, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
func expectEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let lhs = try left(), rhs = try right(); #expect(lhs == rhs, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
func expectThrows<T>(_ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try value(); Issue.record("Expected an error", sourceLocation: sourceLocation) } catch {}
}
func requireValue<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}
