import AppKit
import CryptoKit
import Foundation
import Security

/// A release newer than the one running.
struct Update: Equatable {
    let version: String
    /// The release page, for reading what changed before agreeing to it.
    let page: URL
    let image: URL
    let checksum: URL
}

enum UpdateError: LocalizedError {
    case transport(String)
    case http(Int)
    case malformed
    case incomplete(String)
    case checksumMismatch
    case notTheSameApp
    case failed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .transport(let message): String(localized: "连不上 GitHub：\(message)")
        case .http(let code): String(localized: "GitHub 返回 \(code)")
        case .malformed: String(localized: "看不懂 GitHub 的回复")
        case .incomplete(let version): String(localized: "\(version) 这个版本没有附完整的安装包")
        case .checksumMismatch: String(localized: "下载的文件和它自己的校验和对不上，已经丢掉")
        case .notTheSameApp: String(localized: "下载到的 app 签名和你正在运行的这份不是同一个身份，已经丢掉")
        case .failed(let step, let code): String(localized: "\(step) 失败（\(code)）")
        }
    }
}

/// Replaces this app with a newer release of itself.
///
/// Written rather than taken from Sparkle because the whole app is one binary
/// with nothing linked into it, and the three things an updater needs —
/// the latest version, the file, and a checksum — are already published on the
/// releases page.
///
/// Two checks stand between a download and running it, and neither is optional:
/// the image has to match the checksum published beside it, and the app inside
/// has to satisfy the same code signing requirement this app satisfies. An
/// updater that skips those is a way to run someone else's code as you.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Stage: Equatable {
        case idle
        case checking
        case found(Update)
        case installing
        /// Only after a check the user asked for. A scheduled check that fails
        /// is not news — the network was down, or GitHub was.
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle

    private static let repository = "max1874/type-switch"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Looks for a newer release.
    ///
    /// `asked` separates a check the user clicked from the one on launch: the
    /// first reports everything, including "you are up to date" and any
    /// failure; the second only ever speaks up when there is something to
    /// install.
    func check(asked: Bool) async {
        if case .installing = stage { return }
        stage = .checking
        do {
            let latest = try await Self.latest()
            if Self.isNewer(latest.version, than: Self.currentVersion) {
                stage = .found(latest)
            } else {
                stage = .idle
                if asked { Notice.show(String(localized: "已经是最新的 \(Self.currentVersion)")) }
            }
        } catch {
            stage = asked ? .failed(error.localizedDescription) : .idle
            if asked { Notice.show(error.localizedDescription) }
        }
    }

    /// Downloads, checks, and hands over to a helper that does the replacing —
    /// the one thing this process cannot do, because it is the thing being
    /// replaced.
    func install(_ update: Update) {
        stage = .installing
        Task {
            do {
                let staged = try await Self.fetchAndVerify(update)
                try Self.handOver(to: staged)
                NSApp.terminate(nil)
            } catch {
                stage = .failed(error.localizedDescription)
                Notice.show(error.localizedDescription)
            }
        }
    }

    // MARK: Looking

    static func latest() async throws -> Update {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        )
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Named, and nothing else. GitHub wants a user agent; it does not need
        // to be told which version is asking, and the comparison happens here.
        request.setValue("TypeSwitch", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let pageText = root["html_url"] as? String,
              let page = URL(string: pageText),
              let assets = root["assets"] as? [[String: Any]]
        else { throw UpdateError.malformed }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        func asset(endingIn suffix: String) -> URL? {
            for entry in assets {
                guard let name = entry["name"] as? String, name.hasSuffix(suffix),
                      let text = entry["browser_download_url"] as? String,
                      let url = URL(string: text)
                else { continue }
                return url
            }
            return nil
        }
        // The checksum has to come from the release too. Checking a file
        // against a hash that travelled with it proves only that it arrived
        // intact, which is why the signature check below is the real gate.
        guard let image = asset(endingIn: ".dmg"),
              let checksum = asset(endingIn: ".dmg.sha256")
        else { throw UpdateError.incomplete(version) }

        return Update(version: version, page: page, image: image, checksum: checksum)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = numbers(in: candidate), old = numbers(in: current)
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Leading non-digits are dropped, so a tag that kept its `v` compares the
    /// same as one that did not. The caller strips it too; a version comparison
    /// that silently reads `v1.0.3` as `0.0.3` is not a thing to leave lying
    /// around on the strength of every current caller being careful.
    private static func numbers(in version: String) -> [Int] {
        version.drop { !$0.isNumber }
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    // MARK: Fetching

    /// Returns a verified copy of the new app, outside the disk image.
    ///
    /// `reference` is the app whose signing requirement the download has to
    /// satisfy, and is this one in every real use. It is a parameter so the
    /// same code can be pointed at a known-good pair from the command line.
    static func fetchAndVerify(
        _ update: Update, against reference: URL = Bundle.main.bundleURL
    ) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeSwitch-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            return try await fetch(update, into: staging, against: reference)
        } catch {
            // Out here rather than at each failure inside: the image is still
            // attached at the point a check fails, its mountpoint lives in this
            // directory, and a directory with something mounted in it does not
            // delete. Detaching is the inner function's business, and it has
            // happened by the time this runs.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func fetch(
        _ update: Update, into staging: URL, against reference: URL
    ) async throws -> URL {
        let image = try await download(update.image, into: staging)
        let published = try await downloadText(update.checksum)

        guard let expected = published.split(whereSeparator: \.isWhitespace).first.map(String.init),
              try sha256(of: image).caseInsensitiveCompare(expected) == .orderedSame
        else { throw UpdateError.checksumMismatch }

        let mount = staging.appendingPathComponent("mount")
        // -nobrowse so this never appears in Finder. A staging volume that the
        // user can see is a staging volume they can drag from, and a Finder
        // window on a disk image being worked on is its own kind of trouble.
        try run("/usr/bin/hdiutil",
                ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path],
                step: String(localized: "挂载镜像"))
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], step: "") }

        let inside = mount.appendingPathComponent(
            Bundle.main.bundleURL.lastPathComponent
        )
        try verifySameIdentity(inside, as: reference)

        let staged = staging.appendingPathComponent(inside.lastPathComponent)
        try run("/usr/bin/ditto", [inside.path, staged.path],
                step: String(localized: "取出新版本"))
        try? FileManager.default.removeItem(at: image)
        return staged
    }

    private static func download(_ url: URL, into directory: URL) async throws -> URL {
        let temporary: URL
        do {
            (temporary, _) = try await URLSession.shared.download(from: url)
        } catch {
            throw UpdateError.transport(error.localizedDescription)
        }
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func downloadText(_ url: URL) async throws -> String {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw UpdateError.transport(error.localizedDescription)
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the downloaded app is signed the way this app is signed.
    ///
    /// The requirement is this app's own, read at run time rather than written
    /// down here: a copy signed with someone else's certificate then cannot be
    /// installed over this one, and nothing has to be updated here when the
    /// certificate is renewed. An ad-hoc build's requirement names its own
    /// hash, so a build from source refuses to replace itself with a release —
    /// which is right, they are not the same app.
    static func verifySameIdentity(_ app: URL, as reference: URL = Bundle.main.bundleURL) throws {
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(reference as CFURL, [], &mine) == errSecSuccess,
              let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess,
              let requirement
        else { throw UpdateError.notTheSameApp }

        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess,
              let candidate
        else { throw UpdateError.notTheSameApp }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw UpdateError.notTheSameApp
        }
    }

    // MARK: Handing over

    /// Quit, replace, relaunch — in that order, and from outside this process.
    ///
    /// The order is the whole point. Overwriting a bundle while a process is
    /// running from it leaves that process signed by a bundle that no longer
    /// matches it, and macOS answers by not recognising the app any more: the
    /// Accessibility and Input Monitoring grants quietly stop applying and no
    /// text can be read anywhere. So the helper waits for this process to be
    /// gone before it touches anything.
    private static func handOver(to staged: URL) throws {
        let destination = Bundle.main.bundleURL
        let helper = staged.deletingLastPathComponent().appendingPathComponent("handover.sh")
        try handoverScript.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: helper.path
        )

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            helper.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            destination.path,
        ]
        // Deliberately not waited on: it outlives this process on purpose.
        try task.run()
    }

    /// Held apart from the writing of it so the shipped text is the text that
    /// can be run and checked. A copy of it in a test would be a different
    /// script that happens to look the same today.
    static let handoverScript = """
        #!/bin/sh
        pid=$1
        staged=$2
        destination=$3

        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        sleep 0.3

        # Built beside the old one and swapped in, so a copy that fails partway
        # leaves the working app where it was.
        pending="$destination.update"
        rm -rf "$pending"
        if ditto "$staged" "$pending"; then
            rm -rf "$destination" && mv "$pending" "$destination"
        else
            rm -rf "$pending"
        fi
        rm -rf "$staged"

        # Either the new one or, if the copy failed, the old one.
        open "$destination"
        """

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], step: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw UpdateError.failed(step, task.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
