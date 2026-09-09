import XCTest
@testable import RaiApp

final class FullDiskAccessGuidanceTests: XCTestCase {
    func testNoHelpWithoutAnAccessFailure() {
        XCTAssertFalse(FullDiskAccessGuidance.isAccessFailure(nil))
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
                      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)] {
            XCTAssertFalse(FullDiskAccessGuidance.isAccessFailure(error))
        }
    }

    func testOffersHelpForActualReadAndWriteDenials() {
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))] {
            XCTAssertTrue(FullDiskAccessGuidance.isAccessFailure(error))
        }
    }

    func testRecognizesWrappedAccessFailuresWithoutMatchingErrorText() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(FullDiskAccessGuidance.isAccessFailure(wrapped))
        let unrelated = NSError(domain: "test", code: Int(EACCES),
                                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        XCTAssertFalse(FullDiskAccessGuidance.isAccessFailure(unrelated))
    }
}
