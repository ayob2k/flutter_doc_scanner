import Flutter
import UIKit
import VisionKit
import PDFKit

@available(iOS 13.0, *)
public class SwiftFlutterDocScannerPlugin: NSObject, FlutterPlugin, VNDocumentCameraViewControllerDelegate {

    var resultChannel: FlutterResult?
    var currentMethod: String?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_doc_scanner", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterDocScannerPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard VNDocumentCameraViewController.isSupported else {
            result(FlutterError(code: "UNSUPPORTED", message: "Document scanning is not supported on this device.", details: nil))
            return
        }

        guard let rootVC = UIApplication.shared
                .connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?
                .rootViewController else {
            result(FlutterError(code: "NO_ROOT_VC", message: "Unable to access root view controller.", details: nil))
            return
        }

        self.resultChannel = result
        self.currentMethod = call.method

        let scannerVC = VNDocumentCameraViewController()
        scannerVC.delegate = self
        rootVC.present(scannerVC, animated: true)
    }

    // MARK: - VNDocumentCameraViewControllerDelegate

    public func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true)

        switch currentMethod {
        case "getScannedDocumentAsImages", "getScanDocuments":
            saveScannedImages(scan: scan)
        case "getScannedDocumentAsPdf":
            saveScannedPdf(scan: scan)
        default:
            resultChannel?(FlutterError(code: "UNKNOWN_METHOD", message: "Unsupported method call.", details: currentMethod))
        }
    }

    public func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
        resultChannel?(FlutterError(code: "SCAN_CANCELLED", message: "User cancelled document scan.", details: nil))
    }

    public func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        let alertController = UIAlertController(
            title: "Scanning Failed",
            message: "The document scanning process failed. Would you like to try again?",
            preferredStyle: .alert
        )
        
        let retryAction = UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            // Dismiss current scanner
            controller.dismiss(animated: true) {
                // Present a new scanner
                if let rootVC = UIApplication.shared
                    .connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap({ $0.windows })
                    .first(where: { $0.isKeyWindow })?
                    .rootViewController {
                    let newScannerVC = VNDocumentCameraViewController()
                    newScannerVC.delegate = self
                    rootVC.present(newScannerVC, animated: true)
                }
            }
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            controller.dismiss(animated: true)
            self?.resultChannel?(FlutterError(code: "SCAN_FAILED", 
                                            message: "Document scanning failed. Please try again later.", 
                                            details: error.localizedDescription))
        }
        
        alertController.addAction(retryAction)
        alertController.addAction(cancelAction)
        
        controller.present(alertController, animated: true)
    }

    // MARK: - Helpers

    private func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func saveScannedImages(scan: VNDocumentCameraScan) {
        let dir = getDocumentsDirectory()
        let timestamp = generateTimestamp()
        var filePaths: [String] = []

        for i in 0..<scan.pageCount {
            let image = scan.imageOfPage(at: i)
            let optimizedImage = limitImageSize(image)
            let path = dir.appendingPathComponent("\(timestamp)-\(i).jpg")
            if let data = optimizedImage.jpegData(compressionQuality: 0.8) {
                try? data.write(to: path)
                filePaths.append(path.path)
            }
        }

        resultChannel?(filePaths)
    }

    private func limitImageSize(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 3000.0 // Maximum dimension to prevent memory issues
        let currentWidth = image.size.width
        let currentHeight = image.size.height
        
        // Return original image if it's already within limits
        if currentWidth <= maxDimension && currentHeight <= maxDimension {
            return image
        }
        
        // Calculate new size maintaining aspect ratio
        var newWidth: CGFloat
        var newHeight: CGFloat
        
        if currentWidth > currentHeight {
            newWidth = maxDimension
            newHeight = (currentHeight * maxDimension) / currentWidth
        } else {
            newHeight = maxDimension
            newWidth = (currentWidth * maxDimension) / currentHeight
        }
        
        let newSize = CGSize(width: newWidth, height: newHeight)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(in: CGRect(origin: .zero, size: newSize))
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    private func saveScannedPdf(scan: VNDocumentCameraScan) {
        let dir = getDocumentsDirectory()
        let timestamp = generateTimestamp()
        let pdfPath = dir.appendingPathComponent("\(timestamp).pdf")

        let pdfDoc = PDFDocument()
        for i in 0..<scan.pageCount {
            let image = scan.imageOfPage(at: i)
            let optimizedImage = limitImageSize(image)
            if let pdfPage = PDFPage(image: optimizedImage) {
                pdfDoc.insert(pdfPage, at: pdfDoc.pageCount)
            }
        }

        do {
            try pdfDoc.write(to: pdfPath)
            resultChannel?(pdfPath.path)
        } catch {
            resultChannel?(FlutterError(code: "PDF_WRITE_FAILED", message: "Failed to save PDF file.", details: error.localizedDescription))
        }
    }

    private func generateTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
