import Foundation
import Testing
@testable import FuckYouXcode

struct OpenAIChatClientTests {
    @Test func appendsChatCompletionsPathToProviderBaseURL() throws {
        let url = try OpenAIChatClient.chatCompletionsURL(from: "https://api.example.com/v1")
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func preservesFullChatCompletionsURL() throws {
        let url = try OpenAIChatClient.chatCompletionsURL(from: "https://api.example.com/v1/chat/completions")
        #expect(url.absoluteString == "https://api.example.com/v1/chat/completions")
    }

    @Test func acceptsHostWithoutScheme() throws {
        let url = try OpenAIChatClient.chatCompletionsURL(from: "api.example.com/openai/v1/")
        #expect(url.absoluteString == "https://api.example.com/openai/v1/chat/completions")
    }

    @Test func extractsContentFromStreamingLine() throws {
        let line = #"data: {"choices":[{"delta":{"content":"hello"}}]}"#
        let content = try OpenAIChatClient.streamContent(fromServerSentEventLine: line)
        #expect(content == "hello")
    }

    @Test func ignoresDoneStreamingLine() throws {
        let content = try OpenAIChatClient.streamContent(fromServerSentEventLine: "data: [DONE]")
        #expect(content == nil)
    }
}
