#if os(macOS)
import Containerization
import ContainerizationEXT4
import Foundation
import SystemPackage

/// A Linux virtual machine running one container, booted through Apple's Containerization
/// framework, in which the harness runs commands.
///
/// The container has no network interface. Its main process bridges the guest's loopback port
/// ``proxyPort`` to the host's ``ConnectProxy``, relayed into the guest as a Unix socket, so
/// commands reach the network only through the proxy.
public actor GuestMachine: Machine {
    /// A host directory shared with the guest.
    public struct Share: Sendable {
        /// The directory on the host.
        public let hostPath: URL
        /// Where the guest sees it.
        public let guestPath: String
        /// Whether the guest may only read it.
        public let readOnly: Bool

        public init(hostPath: URL, guestPath: String, readOnly: Bool) {
            self.hostPath = hostPath
            self.guestPath = guestPath
            self.readOnly = readOnly
        }
    }

    /// An ext4 disk image on the host, which the guest mounts as a block device.
    ///
    /// Unlike a ``Share``, its file names are case-sensitive whatever the host's file system is,
    /// and it outlives the guest.
    public struct Disk: Sendable {
        /// The image file on the host.
        public let hostPath: URL
        /// Where the guest mounts it.
        public let guestPath: String

        public init(hostPath: URL, guestPath: String) {
            self.hostPath = hostPath
            self.guestPath = guestPath
        }

        /// Formats an empty, journalled ext4 file system of `sizeInBytes` at ``hostPath`` unless
        /// an image is there already.
        ///
        /// The file is sparse: it takes host disk space only as the guest writes to it.
        ///
        /// - Throws: An error from Containerization's ext4 formatter, leaving no image behind.
        public func formatIfMissing(sizeInBytes: UInt64) throws {
            guard !FileManager.default.fileExists(atPath: hostPath.path) else { return }
            try FileManager.default.createDirectory(at: hostPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Formatted beside the image and moved into place, so a format that fails or is
            // interrupted never leaves a half-written image to mount next time.
            let staging = hostPath.deletingLastPathComponent().appending(path: ".\(hostPath.lastPathComponent)-\(UUID().uuidString)")
            do {
                // Journalled, so a guest stopped mid-build leaves a file system that mounts.
                let formatter = try EXT4.Formatter(FilePath(staging.path), minDiskSize: sizeInBytes, journal: .default)
                try formatter.close()
                try FileManager.default.moveItem(at: staging, to: hostPath)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
    }

    /// The image every guest runs: Swift 6.4.2 on Ubuntu 24.04 (`swift:6.4.2-noble`), pinned by digest. It builds
    /// packages on any tools version up to 6.4.
    public static let image = "docker.io/library/swift@sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0"
    /// Containerization's init filesystem, matching the framework's version.
    public static let initImage = "ghcr.io/apple/containerization/vminit:0.54.0"
    /// The guest loopback port the proxy bridge listens on.
    public static let proxyPort = 3128
    /// The environment that routes a guest command's HTTPS traffic through the proxy.
    public nonisolated var networkEnvironment: [String] {
        ["https_proxy=http://127.0.0.1:\(Self.proxyPort)", "HTTPS_PROXY=http://127.0.0.1:\(Self.proxyPort)"]
    }

    private var manager: ContainerManager
    private let container: LinuxContainer
    private let id: String
    private var processCount = 0

    private init(manager: ContainerManager, container: LinuxContainer, id: String) {
        self.manager = manager
        self.container = container
        self.id = id
    }

    /// Boots a guest.
    ///
    /// - Parameters:
    ///   - kernel: The Linux kernel image.
    ///   - store: Where Containerization keeps images and container filesystems.
    ///   - cpus: The guest's virtual processors.
    ///   - memoryInBytes: The guest's memory, beyond what its kernel and init process use.
    ///   - shares: Host directories to share.
    ///   - disks: Disk images to mount, each formatted already (``Disk/formatIfMissing(sizeInBytes:)``).
    ///   - proxySocket: The host proxy's socket.
    ///   - bridge: The guest path of the proxy bridge script.
    public static func boot(
        kernel: URL,
        store: URL,
        cpus: Int,
        memoryInBytes: UInt64,
        shares: [Share],
        disks: [Disk],
        proxySocket: String,
        bridge: String
    ) async throws -> GuestMachine {
        var manager = try await ContainerManager(
            kernel: Kernel(path: kernel, platform: .linuxArm),
            initfsReference: initImage,
            root: store
        )
        let id = "benchmark-harness-\(ProcessInfo.processInfo.processIdentifier)"
        try? manager.delete(id)
        let resources = VMResources(cpus: cpus, memoryInBytes: memoryInBytes + VMResources.guestMemoryOverhead)
        let container = try await manager.create(
            id,
            reference: image,
            rootfsSizeInBytes: 32.gib(),
            networking: false,
            vm: resources
        ) { @Sendable configuration in
            configuration.cpus = cpus
            configuration.memoryInBytes = memoryInBytes
            configuration.process.arguments = ["/usr/bin/perl", bridge, String(proxyPort), "/run/harness-proxy.sock"]
            configuration.process.stderr = StandardError()
            for share in shares {
                configuration.mounts.append(.share(
                    source: share.hostPath.path,
                    destination: share.guestPath,
                    options: share.readOnly ? ["ro"] : []
                ))
            }
            for disk in disks {
                configuration.mounts.append(.block(format: "ext4", source: disk.hostPath.path, destination: disk.guestPath))
            }
            configuration.sockets.append(UnixSocketConfiguration(
                source: URL(fileURLWithPath: proxySocket),
                destination: URL(fileURLWithPath: "/run/harness-proxy.sock"),
                direction: .into
            ))
        }
        try await container.create()
        try await container.start()
        return GuestMachine(manager: manager, container: container, id: id)
    }

    public func run(
        _ arguments: [String],
        environment: [String],
        input: AsyncStream<Data>?,
        output: AsyncStream<Data>.Continuation?
    ) async throws -> Int32 {
        processCount += 1
        let process = try await container.exec("\(id)-\(processCount)") { @Sendable configuration in
            configuration.arguments = arguments
            configuration.environmentVariables += environment
            configuration.workingDirectory = "/"
            configuration.stdin = input.map(StreamReader.init(source:))
            configuration.stdout = output.map { StreamWriter(continuation: $0) } ?? StandardError()
            configuration.stderr = StandardError()
        }
        // Containerization doesn't always close the writer when the process exits (a benchmark that
        // calls exit(3) mid-protocol leaves it open), so the output also ends here, once the
        // process has exited; a reader waiting for a reply then sees the end instead of waiting
        // forever.
        defer { output?.finish() }
        try await process.start()
        // Cancelling the task kills the command, so a stopped run leaves no process in the guest.
        let status = try await withTaskCancellationHandler {
            try await process.wait()
        } onCancel: {
            Task { try? await process.kill(.kill) }
        }
        try? await process.delete()
        try Task.checkCancellation()
        return status.exitCode
    }

    /// Stops the guest and deletes its container.
    public func shutdown() async {
        try? await container.stop()
        try? manager.delete(id)
    }
}

/// Writes a guest stream to the host's standard error.
struct StandardError: Writer {
    func write(_ data: Data) throws {
        try FileHandle.standardError.write(contentsOf: data)
    }

    func close() throws {}
}

/// Delivers a guest stream as an asynchronous sequence of chunks.
struct StreamWriter: Writer {
    let continuation: AsyncStream<Data>.Continuation

    func write(_ data: Data) throws {
        continuation.yield(data)
    }

    func close() throws {
        continuation.finish()
    }
}

/// Feeds a guest command's input from an asynchronous sequence of chunks.
struct StreamReader: ReaderStream {
    let source: AsyncStream<Data>

    func stream() -> AsyncStream<Data> {
        source
    }
}
#endif
