import Foundation

public enum ExecutableFile {
    public static func isAvailable(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return FileManager.default.isExecutableFile(atPath: path)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
