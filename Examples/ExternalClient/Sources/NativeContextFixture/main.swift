import NativeContextFixtureSupport

@main struct NativeContextFixture {
    static func main() async throws { print(try await NativeContextHostExample.run()) }
}
