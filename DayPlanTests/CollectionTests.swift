import SwiftData
import XCTest
@testable import DayPlan

final class CollectionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.inMemory()
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    func testCollectionCompletionCountsItems() throws {
        let collection = CollectionList(name: "Errands")
        let first = CollectionItem(title: "Groceries", isCompleted: true, collection: collection)
        let second = CollectionItem(title: "Package", collection: collection)
        collection.items.append(first)
        collection.items.append(second)

        context.insert(collection)
        context.insert(first)
        context.insert(second)
        try context.save()

        XCTAssertEqual(collection.completedCount, 1)
        XCTAssertEqual(collection.completionPercentage, 50)
    }
}
