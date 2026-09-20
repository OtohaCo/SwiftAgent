import Foundation
@testable import LiveProviderSupport
import Testing

struct LiveEnvironmentTests {
    @Test func processEnvironmentOverridesSafelyParsedFileValues() throws {
        let file = try temporaryFile(#"""
        # comments and export are supported; values are never executed
        export OPENAI_API_KEY=file-secret
        OPENAI_MODEL="file-model"
        DEEPSEEK_MODLE=legacy-model
        DEEPSEEK_BASE_URL=https://api.deepseek.example/v1
        """#)

        let environment = try LiveEnvironment.load(
            process: ["OPENAI_API_KEY": "process-secret", "OPENAI_MODEL": "process-model"],
            fileURL: file
        )

        #expect(environment.value(for: "OPENAI_API_KEY") == "process-secret")
        #expect(environment.value(for: "OPENAI_MODEL") == "process-model")
        #expect(environment.value(for: "DEEPSEEK_MODEL", aliases: ["DEEPSEEK_MODLE"]) == "legacy-model")
    }

    @Test func localPreflightTreatsAuthenticationAsOptionalButStillRequiresAModelForExecution() throws {
        let options = QualificationOptions(
            provider: .local,
            mode: .live,
            scenario: .preflight,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .local
        )
        let missing = try QualificationConfiguration.preflight(
            options: options,
            environment: LiveEnvironment(process: [:])
        ).rendered
        #expect(missing.contains("credential=OPTIONAL_UNSET"))
        #expect(missing.contains("model=MISSING"))

        #expect(throws: LiveConfigurationError.missingModel("SWIFTAGENT_LOCAL_MODEL")) {
            try QualificationConfiguration.resolve(
                options: options,
                environment: LiveEnvironment(process: [:])
            )
        }
    }

    @Test(arguments: [
        "OPENAI_API_KEY=$(security find-generic-password)",
        "OPENAI_API_KEY=`printenv SECRET`",
        "OPENAI_API_KEY=${OTHER_SECRET}",
        "not an assignment",
    ])
    func executableOrMalformedFileSyntaxIsRejected(_ contents: String) throws {
        let file = try temporaryFile(contents)
        #expect(throws: LiveConfigurationError.self) {
            try LiveEnvironment.load(process: [:], fileURL: file)
        }
    }

    @Test func preflightNeverRendersCredentialValues() throws {
        let secret = "super-secret-value"
        let environment = try LiveEnvironment.load(process: [
            "OPENAI_API_KEY": secret,
            "OPENAI_MODEL": "configured-model",
        ])
        let options = QualificationOptions(
            provider: .openAI,
            mode: .live,
            scenario: .text,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )

        let preflight = try QualificationConfiguration.preflight(options: options, environment: environment)
        let rendered = preflight.rendered

        #expect(rendered.contains("credential=CONFIGURED"))
        #expect(rendered.contains("model=configured-model"))
        #expect(!rendered.contains(secret))
    }

    @Test func preflightRendersExplicitBudgetLimitsWithoutChangingCredentialRedaction() throws {
        let secret = "super-secret-value"
        let environment = try LiveEnvironment.load(process: [
            "OPENAI_API_KEY": secret,
            "OPENAI_MODEL": "configured-model",
            "SWIFT_AGENT_LIVE_PER_PROVIDER_LIMIT": "100",
            "SWIFT_AGENT_LIVE_TOTAL_LIMIT": "500",
        ])
        let limits = try resolvedBudgetLimits(environment: environment)
        let options = QualificationOptions(
            provider: .openAI,
            mode: .live,
            scenario: .preflight,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )

        let rendered = try QualificationConfiguration.preflight(
            options: options,
            environment: environment,
            perProviderLimit: limits.perProviderLimit,
            totalLimit: limits.totalLimit
        ).rendered

        #expect(rendered.contains("provider_request_limit=100"))
        #expect(rendered.contains("total_request_limit=500"))
        #expect(!rendered.contains(secret))
    }

    @Test func gatewayUsesThePublicSUB2APIConfigurationNamespace() throws {
        let secret = "gateway-secret"
        let environment = try LiveEnvironment.load(process: [
            "SUB2API_API_KEY": secret,
            "SUB2API_MODEL": "gateway-model",
            "SUB2API_BASE_URL": "https://gateway.example/v1",
        ])
        let options = QualificationOptions(
            provider: .openAI,
            mode: .live,
            scenario: .preflight,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .gateway
        )

        let preflight = try QualificationConfiguration.preflight(options: options, environment: environment)
        let rendered = preflight.rendered
        #expect(rendered.contains("service=gateway"))
        #expect(rendered.contains("origin=https://gateway.example"))
        #expect(rendered.contains("model=gateway-model"))
        #expect(rendered.contains("credential_variable=SUB2API_API_KEY"))
        #expect(!rendered.contains(secret))
    }

    @Test func gatewayRequiresAnExplicitEndpoint() throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .live,
            scenario: .preflight,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .gateway
        )
        let environment = try LiveEnvironment.load(process: [
            "SUB2API_API_KEY": "gateway-secret",
            "SUB2API_MODEL": "gateway-model",
        ])

        #expect(throws: LiveConfigurationError.invalidEndpoint) {
            try QualificationConfiguration.preflight(options: options, environment: environment)
        }
    }

    @Test func programmaticGatewayOverrideCannotBypassEndpointValidation() throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .live,
            scenario: .preflight,
            modelOverride: "gateway-model",
            endpointOverride: URL(string: "https://operator:secret@gateway.example/v1?route=private")!,
            environmentFile: nil,
            budgetFile: nil,
            service: .gateway
        )

        #expect(throws: LiveConfigurationError.invalidEndpoint) {
            try QualificationConfiguration.preflight(
                options: options,
                environment: LiveEnvironment(process: ["SUB2API_API_KEY": "gateway-secret"])
            )
        }
    }

    @Test func fixturePreflightDoesNotInspectOrRenderLiveConfiguration() throws {
        let environment = try LiveEnvironment.load(process: [
            "ANTHROPIC_API_KEY": "private-secret",
            "ANTHROPIC_BASE_URL": "https://private-gateway.example",
            "SWIFT_AGENT_ANTHROPIC_MODEL": "private-model",
        ])
        let options = QualificationOptions(
            provider: .anthropic,
            mode: .fixture,
            scenario: .preflight,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )

        let rendered = try QualificationConfiguration.preflight(
            options: options,
            environment: environment
        ).rendered

        #expect(rendered.contains("origin=FIXTURE"))
        #expect(rendered.contains("model=fixture"))
        #expect(rendered.contains("credential=UNUSED"))
        #expect(rendered.contains("credential_variable=UNUSED"))
        #expect(!rendered.contains("private-gateway"))
        #expect(!rendered.contains("private-model"))
        #expect(!rendered.contains("private-secret"))
    }

    @Test func fixtureResolutionDoesNotParseLiveEndpointConfiguration() throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .fixture,
            scenario: .text,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )
        let environment = try LiveEnvironment.load(process: [
            "OPENAI_BASE_URL": "::not a URL::",
        ])

        let configuration = try QualificationConfiguration.resolve(
            options: options,
            environment: environment
        )

        #expect(configuration.model == "fixture")
        #expect(configuration.endpoint.host == "fixture.invalid")
    }

    @Test func explicitLiveModeNeverFallsBackWhenCredentialIsMissing() throws {
        let options = QualificationOptions(
            provider: .openAI,
            mode: .live,
            scenario: .text,
            modelOverride: "configured-model",
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .official
        )

        #expect(throws: LiveConfigurationError.missingCredential("OPENAI_API_KEY")) {
            try QualificationConfiguration.resolve(
                options: options,
                environment: LiveEnvironment(process: [:])
            )
        }
    }

    @Test func environmentFileStatusDoesNotExposeTheLocalPath() {
        let path = URL(fileURLWithPath: "/Users/private/operator/.env.live")

        let rendered = renderedEnvironmentFileStatus(path)

        #expect(rendered == "environment_file=CONFIGURED")
        #expect(!rendered.contains("/Users/private"))
    }
}

private func temporaryFile(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftagent-live-environment-")
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(".env.live")
    try Data(contents.utf8).write(to: file)
    return file
}
