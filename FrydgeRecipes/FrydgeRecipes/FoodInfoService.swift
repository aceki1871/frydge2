import Foundation

final class FoodInfoService {
    // Fetch food information based on the ingredient name using OFF search
    func fetchFoodInfo(for ingredient: String, completion: @escaping (Result<OFFProduct, Error>) -> Void) {
        Task {
            let result: Result<OFFProduct, Error> = await withTaskGroup(of: Result<OFFProduct, Error>.self) { group in
                group.addTask {
                    do {
                        let products = try await OpenFoodFactsService.shared.search(ingredient)
                        if let first = products.first {
                            return .success(first)
                        } else {
                            return .failure(NSError(domain: "OpenFoodFacts", code: 404, userInfo: [NSLocalizedDescriptionKey: "No product found"]))
                        }
                    } catch {
                        return .failure(error)
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(8))
                    return .failure(NSError(domain: "OpenFoodFacts", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
                }
                let first = await group.next() ?? Result.failure(NSError(domain: "OpenFoodFacts", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]) as Error)
                group.cancelAll()
                return first
            }
            completion(result)
        }
    }
}
