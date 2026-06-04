import CryptoKit
import Foundation

struct ContentEventDraft: Identifiable, Equatable {
    let id: String
    let sourceIdentifier: String
    let sourceName: String
    let receivedAt: Date
    let title: String
    let body: String
    let url: URL?
    let category: ContentCategory
}

protocol ContentSourceAdapter {
    var identifier: String { get }
    var displayName: String { get }
    func fetchContent(since startDate: Date, until endDate: Date) async throws -> [ContentEventDraft]
}

struct FeedSourceConfiguration: Equatable {
    let identifier: String
    let displayName: String
    let endpointURL: URL
    let category: ContentCategory
    let includeKeywords: [String]
    let excludeKeywords: [String]
    let maxItems: Int

    init(
        identifier: String,
        displayName: String,
        endpointURL: URL,
        category: ContentCategory = .article,
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        maxItems: Int = 30
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.endpointURL = endpointURL
        self.category = category
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.maxItems = min(max(maxItems, 1), 100)
    }
}

enum FeedSourceError: LocalizedError, Equatable {
    case invalidURL
    case httpsRequired
    case credentialsNotAllowed
    case localAddressNotAllowed
    case invalidResponse
    case responseTooLarge
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid feed URL."
        case .httpsRequired:
            "Feed URLs must use HTTPS."
        case .credentialsNotAllowed:
            "Feed URLs cannot contain a username or password."
        case .localAddressNotAllowed:
            "Local and IP-address feed hosts are not allowed."
        case .invalidResponse:
            "The feed returned an invalid response."
        case .responseTooLarge:
            "The feed response exceeded the 2 MB safety limit."
        case .parseFailed:
            "The response was not a readable RSS or Atom feed."
        }
    }
}

enum FeedURLPolicy {
    static let maximumURLLength = 2_048

    static func validatedPublicHTTPSURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumURLLength,
              var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            throw FeedSourceError.invalidURL
        }

        guard components.scheme?.lowercased() == "https" else {
            throw FeedSourceError.httpsRequired
        }
        guard components.user == nil, components.password == nil else {
            throw FeedSourceError.credentialsNotAllowed
        }
        guard isPublicDomainName(host) else {
            throw FeedSourceError.localAddressNotAllowed
        }

        components.fragment = nil
        guard let url = components.url else {
            throw FeedSourceError.invalidURL
        }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        (try? validatedPublicHTTPSURL(from: url.absoluteString)) != nil
    }

    private static func isPublicDomainName(_ host: String) -> Bool {
        guard host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              host != "::1",
              !host.contains(":"),
              !isIPv4Address(host)
        else {
            return false
        }
        return host.contains(".")
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
}

struct RSSFeedAdapter: ContentSourceAdapter {
    static let maximumResponseBytes = 2 * 1_024 * 1_024

    let configuration: FeedSourceConfiguration

    var identifier: String { configuration.identifier }
    var displayName: String { configuration.displayName }

    func fetchContent(since startDate: Date, until endDate: Date) async throws -> [ContentEventDraft] {
        var request = URLRequest(
            url: configuration.endpointURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue(
            "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9",
            forHTTPHeaderField: "Accept"
        )

        let delegate = SecureFeedSessionDelegate()
        let session = URLSession(configuration: Self.sessionConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let finalURL = httpResponse.url,
              FeedURLPolicy.isAllowed(finalURL)
        else {
            throw FeedSourceError.invalidResponse
        }

        guard response.expectedContentLength <= 0 ||
                response.expectedContentLength <= Int64(Self.maximumResponseBytes)
        else {
            throw FeedSourceError.responseTooLarge
        }

        var data = Data()
        data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), Self.maximumResponseBytes))
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw FeedSourceError.responseTooLarge
            }
            data.append(byte)
        }

        return try RSSAtomFeedParser.parse(
            data: data,
            configuration: configuration,
            since: startDate,
            until: endDate
        )
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return configuration
    }
}

private final class SecureFeedSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, FeedURLPolicy.isAllowed(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum RSSAtomFeedParser {
    static func parse(
        data: Data,
        configuration: FeedSourceConfiguration,
        since startDate: Date,
        until endDate: Date
    ) throws -> [ContentEventDraft] {
        let delegate = FeedXMLParserDelegate(
            configuration: configuration,
            startDate: startDate,
            endDate: endDate
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw FeedSourceError.parseFailed
        }
        return Array(
            delegate.drafts
                .sorted { $0.receivedAt > $1.receivedAt }
                .prefix(configuration.maxItems)
        )
    }
}

private final class FeedXMLParserDelegate: NSObject, XMLParserDelegate {
    struct ItemBuilder {
        var id = ""
        var title = ""
        var body = ""
        var link: URL?
        var publishedAt: Date?
    }

    let configuration: FeedSourceConfiguration
    let startDate: Date
    let endDate: Date

    private(set) var drafts: [ContentEventDraft] = []
    private var currentItem: ItemBuilder?
    private var currentText = ""

    init(configuration: FeedSourceConfiguration, startDate: Date, endDate: Date) {
        self.configuration = configuration
        self.startDate = startDate
        self.endDate = endDate
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        let name = normalized(elementName)
        if name == "item" || name == "entry" {
            currentItem = ItemBuilder()
        } else if name == "link",
                  let href = attributeDict["href"],
                  let url = try? FeedURLPolicy.validatedPublicHTTPSURL(from: href) {
            currentItem?.link = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) {
            currentText += value
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalized(elementName)
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if name == "item" || name == "entry" {
            appendCurrentItem()
            currentItem = nil
            currentText = ""
            return
        }

        guard currentItem != nil else {
            currentText = ""
            return
        }

        switch name {
        case "guid", "id":
            if currentItem?.id.isEmpty == true {
                currentItem?.id = value
            }
        case "title":
            currentItem?.title = FeedTextSanitizer.clean(value, limit: 240)
        case "description", "summary", "content", "content:encoded", "encoded":
            let body = FeedTextSanitizer.clean(value, limit: 1_200)
            if body.count > (currentItem?.body.count ?? 0) {
                currentItem?.body = body
            }
        case "link":
            if currentItem?.link == nil,
               let url = try? FeedURLPolicy.validatedPublicHTTPSURL(from: value) {
                currentItem?.link = url
            }
        case "pubdate", "published", "updated", "dc:date", "date":
            if currentItem?.publishedAt == nil {
                currentItem?.publishedAt = FeedDateParser.date(from: value)
            }
        default:
            break
        }

        currentText = ""
    }

    private func appendCurrentItem() {
        guard let item = currentItem else { return }

        let receivedAt = item.publishedAt ?? endDate.addingTimeInterval(-1)
        guard receivedAt >= startDate, receivedAt < endDate else { return }

        let title = item.title.isEmpty ? "Untitled item" : item.title
        let body = item.body.isEmpty ? title : item.body
        guard matchesFilters(title: title, body: body) else { return }

        let stableValue = item.id.isEmpty
            ? "\(item.link?.absoluteString ?? "")|\(title)|\(receivedAt.timeIntervalSince1970)"
            : item.id
        let externalID = "rss.\(configuration.identifier).\(stableHash(stableValue))"

        drafts.append(ContentEventDraft(
            id: externalID,
            sourceIdentifier: configuration.identifier,
            sourceName: configuration.displayName,
            receivedAt: receivedAt,
            title: title,
            body: body,
            url: item.link,
            category: configuration.category
        ))
    }

    private func matchesFilters(title: String, body: String) -> Bool {
        let searchable = "\(title) \(body)".localizedLowercase
        let includes = configuration.includeKeywords
            .map(\.localizedLowercase)
            .filter { !$0.isEmpty }
        let excludes = configuration.excludeKeywords
            .map(\.localizedLowercase)
            .filter { !$0.isEmpty }

        guard includes.isEmpty || includes.contains(where: searchable.contains) else {
            return false
        }
        return !excludes.contains(where: searchable.contains)
    }

    private func normalized(_ elementName: String) -> String {
        elementName.lowercased()
    }

    private func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum FeedDateParser {
    static func date(from value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

private enum FeedTextSanitizer {
    static func clean(_ value: String, limit: Int) -> String {
        let withoutTags = value.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        let collapsed = decoded.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return String(collapsed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

struct SampleContentAdapter: ContentSourceAdapter {
    let identifier = "sample.local"
    let displayName = "Sample Inbox"

    func fetchContent(since startDate: Date, until endDate: Date) async throws -> [ContentEventDraft] {
        let calendar = Calendar.current
        let base = DateKeys.startOfDay(startDate, calendar: calendar)

        let drafts = [
            draft(
                suffix: "morning-brief",
                offsetHour: 8,
                title: "Morning brief",
                body: "Three calendar nudges and one reading reminder were captured for review.",
                category: .calendar,
                base: base,
                calendar: calendar
            ),
            draft(
                suffix: "focus-followup",
                offsetHour: 13,
                title: "Focus follow-up",
                body: "A project note and two task prompts were grouped as afternoon follow-ups.",
                category: .task,
                base: base,
                calendar: calendar
            ),
            draft(
                suffix: "evening-reading",
                offsetHour: 19,
                title: "Evening reading queue",
                body: "Two saved links looked relevant to planning and one was tagged for later.",
                category: .article,
                base: base,
                calendar: calendar
            )
        ]

        return drafts.filter { $0.receivedAt >= startDate && $0.receivedAt < endDate }
    }

    private func draft(
        suffix: String,
        offsetHour: Int,
        title: String,
        body: String,
        category: ContentCategory,
        base: Date,
        calendar: Calendar
    ) -> ContentEventDraft {
        let receivedAt = calendar.date(byAdding: .hour, value: offsetHour, to: base) ?? base
        return ContentEventDraft(
            id: "\(identifier).\(DateKeys.dayKey(for: base)).\(suffix)",
            sourceIdentifier: identifier,
            sourceName: displayName,
            receivedAt: receivedAt,
            title: title,
            body: body,
            url: nil,
            category: category
        )
    }
}
