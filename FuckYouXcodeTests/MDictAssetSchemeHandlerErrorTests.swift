import Foundation
import Testing
@testable import FuckYouXcode

struct MDictAssetSchemeHandlerErrorTests {
    @Test func schemeErrorCarriesCodeAndURL() {
        let url = URL(string: "dict://asset/demo/missing.css")
        let error = MDictAssetSchemeHandler.makeSchemeError(
            code: 404,
            message: "Resource not found",
            requestURL: url
        )

        #expect(error.domain == "MDictAssetSchemeHandler")
        #expect(error.code == 404)
        #expect(error.localizedDescription == "Resource not found")
        #expect((error.userInfo[NSURLErrorKey] as? URL) == url)
    }
}
