import UIKit
import Photos
import Combine

extension NSObject {
    func associatedObject<T>(for key: UnsafeRawPointer, initialValue: () -> T) -> T {
        objc_getAssociatedObject(self, key) as! T? ?? {
            let result = initialValue()
            objc_setAssociatedObject(self, key, result, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return result
        }()
    }
}

private let storeKey = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)
extension Cancellable {
    func store(in object: NSObject) {
        object
            .associatedObject(for: storeKey, initialValue: NSMutableArray.init)
            .add(self)
    }
}

private let imagePublisehrsKey = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)
extension UIImageView {
    public var imagePublishers: PassthroughSubject<AnyPublisher<UIImage?, Never>, Never> {
        associatedObject(for: imagePublisehrsKey) {
            let subject = PassthroughSubject<AnyPublisher<UIImage?, Never>, Never>()
            subject
                .switchToLatest()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] image in self?.image = image }
                .store(in: self)
            return subject
        }
    }
}

extension PHFetchResult<PHAsset> {
    var allObjects: AnyCollection<ObjectType> {
        .init((0..<count).lazy.map(object(at:)))
    }
}

extension PHFetchResult<PHAssetCollection> {
    var allObjects: AnyCollection<ObjectType> {
        .init((0..<count).lazy.map(object(at:)))
    }
}

extension PHPhotoLibrary {

    func changes() -> ChangesPublisher {
        .init(library: self)
    }

    func changeDetails<T: PHObject>(for fetchResult: PHFetchResult<T>) -> AnyPublisher<PHFetchResultChangeDetails<T>, Never> {
        changes()
            .scan(.init(from: fetchResult, to: fetchResult, changedObjects: [])) { details, change in
                change.changeDetails(for: details.fetchResultAfterChanges) ?? details
            }
            .removeDuplicates(by: ===)
            .eraseToAnyPublisher()
    }

    func publisher<T: PHObject>(for fetchResult: PHFetchResult<T>) -> AnyPublisher<PHFetchResultChangeDetails<T>, Never> {
        changeDetails(for: fetchResult)
            .receive(on: DispatchQueue.main)
            .prepend(InitialFetchResultChangeDetails(fetchResult: fetchResult) as! PHFetchResultChangeDetails<T>)
            .eraseToAnyPublisher()
    }

    struct ChangesPublisher: Publisher {
        typealias Output = PHChange
        typealias Failure = Never

        let library: PHPhotoLibrary

        func receive<S: Subscriber<Output, Failure>>(subscriber: S) {
            subscriber.receive(subscription: Subscription(library: library, subscriber: subscriber))
        }

        class Subscription<S: Subscriber<PHChange, Never>>: NSObject, Combine.Subscription, PHPhotoLibraryChangeObserver {
            let library: PHPhotoLibrary
            let subscriber: S?

            init(library: PHPhotoLibrary, subscriber: S) {
                self.library = library
                self.subscriber = subscriber
                super.init()
                library.register(self)
            }

            deinit {
                library.unregisterChangeObserver(self)
            }

            func request(_ demand: Subscribers.Demand) {}

            func cancel() {
                library.unregisterChangeObserver(self)
            }

            func photoLibraryDidChange(_ changeInstance: PHChange) {
                if let subscriber {
                    _ = subscriber.receive(changeInstance)
                }
            }
        }
    }

    private final class InitialFetchResultChangeDetails: PHFetchResultChangeDetails<PHObject>, @unchecked Sendable {
        let fetchResult: PHFetchResult<PHObject>
        init<T: PHObject>(fetchResult: PHFetchResult<T>) {
            self.fetchResult = fetchResult as! PHFetchResult<PHObject>
        }
        override var fetchResultBeforeChanges: PHFetchResult<PHObject> { fetchResult }
        override var fetchResultAfterChanges: PHFetchResult<PHObject> { fetchResult }
        override var hasIncrementalChanges: Bool { false }
    }
}

extension PHImageManager {

    func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode, options: PHImageRequestOptions?) -> ImagePublisher {
        .init(request: .init(manager: self, asset: asset, targetSize: targetSize, contentMode: contentMode, options: options))
    }

    struct ImagePublisher: Publisher {
        typealias Output = (image: UIImage, isDegraded: Bool)
        typealias Failure = PHPhotosError

        struct Request {
            let manager: PHImageManager
            let asset: PHAsset
            let targetSize: CGSize
            let contentMode: PHImageContentMode
            let options: PHImageRequestOptions?
        }

        let request: Request

        init(request: Request) {
            self.request = request
        }

        func receive<S: Subscriber<Output, Failure>>(subscriber: S) {
            subscriber.receive(subscription: Subscription(subscriber: subscriber, request: request))
        }

        class Subscription<S: Subscriber<Output, Failure>>: Combine.Subscription {

            var subscriber: S?
            let request: Request
            var requestId = PHInvalidImageRequestID

            init(subscriber: S, request: Request) {
                self.subscriber = subscriber
                self.request = request
            }

            func cancel() {
                subscriber = nil
                request.manager.cancelImageRequest(requestId)
            }

            func request(_ demand: Subscribers.Demand) {
                guard requestId == PHInvalidImageRequestID else { return }
                requestId = request.manager.requestImage(
                    for: request.asset,
                    targetSize: request.targetSize,
                    contentMode: request.contentMode,
                    options: request.options,
                    resultHandler: resultHandler
                )
            }

            func resultHandler(image: UIImage?, info: [AnyHashable: Any]?) {
                assert(
                    requestId == PHInvalidImageRequestID
                    || requestId == info?[PHImageResultRequestIDKey] as! PHImageRequestID?,
                    "Unexpected request id"
                )

                if let error = info?[PHImageErrorKey] {
                    let phError = error as? PHPhotosError
                    assert(phError != nil, "Uexpected error type")
                    let reportedError = phError ?? PHPhotosError(.internalError)
                    subscriber?.receive(completion: .failure(reportedError))
                    subscriber = nil
                } else if let image {
                    let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool == true
                    _ = subscriber?.receive((image: image, isDegraded: isDegraded))
                    if !isDegraded {
                        subscriber?.receive(completion: .finished)
                        subscriber = nil
                    }
                } else {
                    assert(false, "Unexpected outcome")
                    subscriber?.receive(completion: .failure(PHPhotosError(.internalError)))
                    subscriber = nil
                }
            }
        }
    }
}
