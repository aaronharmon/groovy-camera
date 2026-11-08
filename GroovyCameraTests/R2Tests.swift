import Foundation
import Testing
@testable import GroovyCamera

struct R2Tests {
    /// AWS's published example of a presigned GET, from "Authenticating Requests: Using Query
    /// Parameters" in the S3 docs. The keys are AWS's public example values.
    @Test func matchesAWSPresignedExample() {
        let url = S3Signer.presignedURL(
            method: "GET",
            host: "examplebucket.s3.amazonaws.com",
            path: "/test.txt",
            credentials: S3Signer.Credentials(
                accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
            ),
            region: "us-east-1",
            date: Date(timeIntervalSince1970: 1_369_353_600),
            expires: 86400
        )
        #expect(url.absoluteString == "https://examplebucket.s3.amazonaws.com/test.txt"
            + "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404") // secret-scan: allow (AWS example)
    }

    private let credentials = R2Credentials(
        accountID: "exampleaccount",
        bucket: "example-bucket",
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )

    @Test func putsPhotosUnderRecordsWithTheirDisplayHeadersSigned() throws {
        let key = R2Client.key(folder: "2026-11-07-143205", slot: Slot(number: 1))
        #expect(key == "records/2026-11-07-143205/2026-11-07-143205-01-front.jpg")

        let request = try #require(R2Client(credentials: credentials).photoUpload(key: key))
        let url = try #require(request.url)
        #expect(request.httpMethod == "PUT")
        #expect(url.host() == "exampleaccount.r2.cloudflarestorage.com")
        #expect(url.path() == "/example-bucket/records/2026-11-07-143205/2026-11-07-143205-01-front.jpg")
        #expect(url.query()?.contains("X-Amz-SignedHeaders=cache-control%3Bcontent-type%3Bhost") == true)
        #expect(url.query()?.contains("X-Amz-Expires=604800") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "public, max-age=86400")
    }

    @Test func refusesToWriteOutsideRecords() {
        let client = R2Client(credentials: credentials)
        #expect(client.request(method: "PUT", key: "other/file.jpg") == nil)
        #expect(client.request(method: "PUT", key: "records/") == nil)
        #expect(client.request(method: "PUT", key: "records/../other.jpg") == nil)
    }

    @Test func needsEveryCredential() {
        #expect(credentials.isComplete)
        var missing = credentials
        missing.secretAccessKey = " "
        #expect(!missing.isComplete)
    }
}
