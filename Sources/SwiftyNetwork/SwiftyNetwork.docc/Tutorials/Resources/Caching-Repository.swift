import SwiftyNetwork

let repository = GenericRepository(
    networkDataSource: NetworkClient.shared,
    localDataSource: local
)
