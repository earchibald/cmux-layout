import Testing
import Foundation
@testable import CMUXLayout

@Suite("Interpolator Tests")
struct InterpolatorTests {
    let env = ["HOME": "/Users/test", "PROJECT": "myapp", "EMPTY": ""]

    @Test func simpleVar() {
        #expect(Interpolator.resolve("$HOME/logs", environment: env) == "/Users/test/logs")
    }

    @Test func bracedVar() {
        #expect(Interpolator.resolve("${HOME}/logs", environment: env) == "/Users/test/logs")
    }

    @Test func varWithDefault_unset() {
        #expect(Interpolator.resolve("${MISSING:-fallback}", environment: env) == "fallback")
    }

    @Test func varWithDefault_set() {
        #expect(Interpolator.resolve("${PROJECT:-fallback}", environment: env) == "myapp")
    }

    @Test func varWithDefault_empty() {
        #expect(Interpolator.resolve("${EMPTY:-fallback}", environment: env) == "fallback")
    }

    @Test func escapedDollar() {
        #expect(Interpolator.resolve("price is $$5", environment: env) == "price is $5")
    }

    @Test func unresolvedVarBecomesEmpty() {
        #expect(Interpolator.resolve("$NOPE/path", environment: env) == "/path")
    }

    @Test func mixedPatterns() {
        #expect(Interpolator.resolve("cd $HOME/${PROJECT:-default} && echo $$done", environment: env)
            == "cd /Users/test/myapp && echo $done")
    }

    @Test func noVars() {
        #expect(Interpolator.resolve("just plain text", environment: env) == "just plain text")
    }

    @Test func emptyString() {
        #expect(Interpolator.resolve("", environment: env) == "")
    }

    @Test func varAtEnd() {
        #expect(Interpolator.resolve("path/$PROJECT", environment: env) == "path/myapp")
    }

    @Test func bracedVarAtEnd() {
        #expect(Interpolator.resolve("path/${PROJECT}", environment: env) == "path/myapp")
    }
}
