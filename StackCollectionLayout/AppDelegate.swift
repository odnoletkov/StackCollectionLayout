import UIKit
import Photos

@main
class AppDelegate: NSObject, UIApplicationDelegate {
    lazy var mainWindow = UIWindow()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        mainWindow.rootViewController = .init()
        mainWindow.makeKeyAndVisible()

        Task { @MainActor in
            await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            let controller = AssetCollectionsController(style: .insetGrouped)
            mainWindow.rootViewController = UINavigationController(rootViewController: controller)
        }

        return true
    }
}

class AssetCollectionsController: UITableViewController {
    enum Section: Hashable {
        case allowMoves(Bool)
    }
    struct Item: Hashable {
        let allowMoves: Bool
        let assetCollection: PHAssetCollection
    }

    let imageManager = PHImageManager()

    lazy var dataSource = DataSource(tableView: tableView) { [tableView = tableView!, imageManager] cell, indexPath, item in
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.textLabel?.text = item.assetCollection.localizedTitle
        cell.accessoryView = UICollectionView(assetCollection: item.assetCollection, allowMoves: item.allowMoves, imageManager: imageManager)
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for allowMoves in [true, false] {
            snapshot.appendSections([.allowMoves(allowMoves)])
            snapshot.appendItems(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).allObjects.map { .init(allowMoves: allowMoves, assetCollection: $0) })
            snapshot.appendItems(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).allObjects.map { .init(allowMoves: allowMoves, assetCollection: $0) })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    class DataSource: UITableViewDiffableDataSource<Section, Item> {
        override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            String(describing: sectionIdentifier(for: section)!)
        }
    }
}

class TrailingStackLayout: UICollectionViewLayout {
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.zIndex = indexPath.row
        let size = collectionView!.bounds.size.height
        attributes.frame = .init(x: size/2 * CGFloat(indexPath.row), y: 0, width: size, height: size)
        attributes.transform = collectionView!.transform
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        (0..<collectionView!.numberOfSections)
            .flatMap { section in
                (0..<collectionView!.numberOfItems(inSection: section))
                    .map { item in IndexPath(item: item, section: section) }
            }
            .compactMap(layoutAttributesForItem(at:))
    }
}

extension UICollectionView {
    convenience init(assetCollection: PHAssetCollection, allowMoves: Bool, imageManager: PHImageManager) {
        self.init(
            frame: .init(x: 0, y: 0, width: 200, height: 40),
            collectionViewLayout: TrailingStackLayout()
        )

        transform = switch UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) {
        case .leftToRight:
            .init(scaleX: -1, y: 1)
        case .rightToLeft:
            .identity
        @unknown default:
            .identity
        }

        class Cell: UICollectionViewCell {
            let imageView = UIImageView()
            override init(frame: CGRect) {
                super.init(frame: frame)
                imageView.contentMode = .scaleAspectFill
                imageView.layer.cornerRadius = 10
                imageView.layer.borderWidth = 2
                imageView.layer.borderColor = UIColor.white.cgColor
                imageView.clipsToBounds = true
                backgroundView = imageView
            }
            required init?(coder: NSCoder) { fatalError() }
        }

        let cellRegistration = UICollectionView.CellRegistration<Cell, PHAsset> { cell, _, asset in
            cell.imageView.imagePublishers.send(
                imageManager
                    .requestImage(for: asset, targetSize: .init(width: 120, height: 120), contentMode: .aspectFill, options: nil)
                    .map(\.image)
                    .map(Optional.init)
                    .prepend(nil)
                    .replaceError(with: nil)
                    .eraseToAnyPublisher()
            )
        }

        let cellProvider: UICollectionViewDiffableDataSource<Int, PHAsset>.CellProvider = { [cellRegistration] collectionView, indexPath, itemIdentifier in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: itemIdentifier)
        }

        let assets = PHPhotoLibrary.shared()
            .publisher(for: PHAsset.fetchAssets(in: assetCollection, options: nil))
            .map(\.fetchResultAfterChanges.allObjects)
            .map(Array.init)

        if allowMoves {
            let dataSource = UICollectionViewDiffableDataSource<Int, PHAsset>(collectionView: self, cellProvider: cellProvider)
            assets
                .sink { assets in
                    var snapshot = NSDiffableDataSourceSnapshot<Int, PHAsset>()
                    snapshot.appendSections([0])
                    snapshot.appendItems(assets)
                    dataSource.apply(snapshot, animatingDifferences: true)
                }
                .store(in: self)
        } else {
            let dataSource = NoMovesDataSource(collectionView: self, cellProvider: cellProvider)
            assets
                .sink { assets in
                    dataSource.apply(assets, animatingDifferences: true)
                }
                .store(in: self)
        }
    }
}

class NoMovesDataSource<Item: Hashable> {
    let underlyingDataSource: UICollectionViewDiffableDataSource<Int, UUID>
    let section = 0
    class Mapping {
        var value: [UUID: Item] = [:]
    }
    let mapping = Mapping()

    init(collectionView: UICollectionView, cellProvider: @escaping UICollectionViewDiffableDataSource<Int, Item>.CellProvider) {
        underlyingDataSource = .init(collectionView: collectionView) { [mapping] collectionView, indexPath, itemIdentifier in
            cellProvider(collectionView, indexPath, mapping.value[itemIdentifier]!)
        }
    }

    func apply(_ newItems: [Item], animatingDifferences: Bool) {
        let oldItems = underlyingDataSource.snapshot(for: section).items.map { mapping.value[$0]! }

        let differenceWithoutMoves = newItems.difference(from: oldItems)
        let insertedItems = differenceWithoutMoves.insertions.map(\.element)
        let uniqueInserted = Set(insertedItems)
        precondition(insertedItems.count == uniqueInserted.count, "Duplicate items not supported")

        let remainingIdsToItems = mapping.value.filter { _, item in !uniqueInserted.contains(item) }
        let remainingItemsToIds = Dictionary(uniqueKeysWithValues: remainingIdsToItems.map { ($1, $0) })

        let newIds = newItems.map { item in remainingItemsToIds[item] ?? UUID() }
        mapping.value = Dictionary(uniqueKeysWithValues: zip(newIds, newItems))

        var newSnapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        newSnapshot.appendSections([section])
        newSnapshot.appendItems(newIds)
        underlyingDataSource.apply(newSnapshot, animatingDifferences: animatingDifferences)
    }
}

extension CollectionDifference.Change {
    var element: ChangeElement {
        switch self {
        case .insert(_, let element, _), .remove(_, let element, _):
            element
        }
    }
}
