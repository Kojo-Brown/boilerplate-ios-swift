import Testing
import Foundation
@testable import BoilerplateiOSSwift

// MARK: - Fixtures

private let decoder = JSONDecoder.apiDecoder
private let encoder = JSONEncoder.apiEncoder

// MARK: - User

@Suite("User CodingKeys")
struct UserCodingKeysTests {

    @Test func decodesFromSnakeCaseJSON() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "email": "alice@example.com",
            "name": "Alice",
            "avatar_url": "https://example.com/avatar.png",
            "created_at": "2024-01-15T10:00:00Z",
            "updated_at": "2024-06-01T12:30:00Z"
        }
        """.data(using: .utf8)!

        let user = try decoder.decode(User.self, from: json)

        #expect(user.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(user.email == "alice@example.com")
        #expect(user.name == "Alice")
        #expect(user.avatarURL == URL(string: "https://example.com/avatar.png"))
        #expect(user.createdAt != nil)
        #expect(user.updatedAt != nil)
    }

    @Test func decodesWithOptionalFieldsAbsent() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000002",
            "email": "bob@example.com",
            "name": "Bob"
        }
        """.data(using: .utf8)!

        let user = try decoder.decode(User.self, from: json)

        #expect(user.email == "bob@example.com")
        #expect(user.avatarURL == nil)
        #expect(user.createdAt == nil)
        #expect(user.updatedAt == nil)
    }

    @Test func encodesToSnakeCaseJSON() throws {
        let user = User(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            email: "carol@example.com",
            name: "Carol",
            avatarURL: URL(string: "https://example.com/carol.png")
        )

        let data = try encoder.encode(user)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["email"] as? String == "carol@example.com")
        #expect(dict["avatar_url"] as? String == "https://example.com/carol.png")
        #expect(dict["created_at"] == nil)
    }

    @Test func roundTripsWithoutDataLoss() throws {
        let original = User(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            email: "dave@example.com",
            name: "Dave"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(User.self, from: data)

        #expect(decoded == original)
    }
}

// MARK: - AuthModels

@Suite("Auth model CodingKeys")
struct AuthModelCodingKeysTests {

    @Test func loginRequestEncodesToSnakeCase() throws {
        let request = LoginRequest(email: "user@example.com", password: "secret")
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["email"] as? String == "user@example.com")
        #expect(dict["password"] as? String == "secret")
    }

    @Test func loginResponseDecodesFromSnakeCase() throws {
        let json = """
        {
            "access_token": "eyJhbGc.payload.sig",
            "refresh_token": "rt_abc123",
            "user": {
                "id": "00000000-0000-0000-0000-000000000005",
                "email": "user@example.com",
                "name": "Test User"
            }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(LoginResponse.self, from: json)

        #expect(response.accessToken == "eyJhbGc.payload.sig")
        #expect(response.refreshToken == "rt_abc123")
        #expect(response.user.email == "user@example.com")
    }

    @Test func updateProfileRequestEncodesName() throws {
        let request = UpdateProfileRequest(name: "Updated Name")
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["name"] as? String == "Updated Name")
    }
}

// MARK: - TokenPair

@Suite("TokenPair CodingKeys")
struct TokenPairCodingKeysTests {

    @Test func tokenPairDecodesFromSnakeCase() throws {
        let json = """
        {
            "access_token": "acc_tok",
            "refresh_token": "ref_tok"
        }
        """.data(using: .utf8)!

        let pair = try decoder.decode(TokenPair.self, from: json)

        #expect(pair.accessToken == "acc_tok")
        #expect(pair.refreshToken == "ref_tok")
    }

    @Test func tokenRefreshRequestEncodesToSnakeCase() throws {
        let request = TokenRefreshRequest(refreshToken: "rt_xyz")
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(dict["refresh_token"] as? String == "rt_xyz")
        #expect(dict["refreshToken"] == nil)
    }
}

// MARK: - APIResponse

@Suite("APIResponse CodingKeys")
struct APIResponseCodingKeysTests {

    private struct Item: Decodable, Sendable, Equatable {
        let id: Int
        let label: String
    }

    @Test func decodesSuccessEnvelope() throws {
        let json = """
        {
            "data": { "id": 42, "label": "hello" },
            "meta": { "request_id": "req-001", "version": "1.0" }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(APIResponse<Item>.self, from: json)

        #expect(response.data?.id == 42)
        #expect(response.data?.label == "hello")
        #expect(response.error == nil)
        #expect(response.meta?.requestID == "req-001")
        #expect(response.meta?.version == "1.0")
    }

    @Test func decodesErrorEnvelope() throws {
        let json = """
        {
            "error": {
                "code": "not_found",
                "message": "Resource not found.",
                "details": { "field": "id" }
            }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(APIResponse<Item>.self, from: json)

        #expect(response.data == nil)
        #expect(response.error?.code == "not_found")
        #expect(response.error?.message == "Resource not found.")
        #expect(response.error?.details?["field"] == "id")
        #expect(response.error?.errorDescription == "Resource not found.")
    }

    @Test func responseMetaDecodesRequestID() throws {
        let json = """
        { "request_id": "abc-123", "version": "2.0" }
        """.data(using: .utf8)!

        let meta = try decoder.decode(ResponseMeta.self, from: json)

        #expect(meta.requestID == "abc-123")
        #expect(meta.version == "2.0")
    }

    @Test func responseMetaHandlesMissingFields() throws {
        let json = "{}".data(using: .utf8)!
        let meta = try decoder.decode(ResponseMeta.self, from: json)

        #expect(meta.requestID == nil)
        #expect(meta.version == nil)
    }
}

// MARK: - Pagination

@Suite("Pagination CodingKeys")
struct PaginationCodingKeysTests {

    private struct Item: Decodable, Sendable, Equatable {
        let id: Int
    }

    @Test func pageDecodesItemsAndInfo() throws {
        let json = """
        {
            "items": [{ "id": 1 }, { "id": 2 }],
            "pagination": {
                "page": 2,
                "per_page": 20,
                "total": 45,
                "total_pages": 3
            }
        }
        """.data(using: .utf8)!

        let page = try decoder.decode(Page<Item>.self, from: json)

        #expect(page.items.count == 2)
        #expect(page.items.first?.id == 1)
        #expect(page.pagination.page == 2)
        #expect(page.pagination.perPage == 20)
        #expect(page.pagination.total == 45)
        #expect(page.pagination.totalPages == 3)
        #expect(page.pagination.hasNextPage == true)
        #expect(page.pagination.hasPreviousPage == true)
    }

    @Test func pageInfoFirstPageHasNoPreview() throws {
        let info = PageInfo(page: 1, perPage: 10, total: 5, totalPages: 1)

        #expect(!info.hasPreviousPage)
        #expect(!info.hasNextPage)
    }

    @Test func cursorPageDecodesItemsAndCursor() throws {
        let json = """
        {
            "items": [{ "id": 10 }, { "id": 11 }],
            "cursor": {
                "next_cursor": "cursor_abc",
                "prev_cursor": null,
                "has_more": true
            }
        }
        """.data(using: .utf8)!

        let page = try decoder.decode(CursorPage<Item>.self, from: json)

        #expect(page.items.count == 2)
        #expect(page.cursor.nextCursor == "cursor_abc")
        #expect(page.cursor.prevCursor == nil)
        #expect(page.cursor.hasMore == true)
    }

    @Test func cursorInfoDecodesEndOfList() throws {
        let json = """
        {
            "next_cursor": null,
            "prev_cursor": "cursor_xyz",
            "has_more": false
        }
        """.data(using: .utf8)!

        let cursor = try decoder.decode(CursorInfo.self, from: json)

        #expect(cursor.nextCursor == nil)
        #expect(cursor.prevCursor == "cursor_xyz")
        #expect(cursor.hasMore == false)
    }
}
