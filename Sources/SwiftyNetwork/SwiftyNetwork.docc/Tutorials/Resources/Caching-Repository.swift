import SwiftyNetwork

let repository = GenericRepository(
    client: NetworkClient.shared,
    localDataSource: local
)
