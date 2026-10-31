#if os(macOS)
import Containerization
import Foundation

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

    /// The image every guest runs: Swift 6.3 on Ubuntu 24.04, pinned by digest.
    public static let image = "docker.io/library/swift@sha256:1038d54c80063f5cdfabc4560990c30af64b5de8ebf28161deb22ca4ad5db866"
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
    ///   - proxySocket: The host proxy's socket.
    ///   - bridge: The guest path of the proxy bridge script.
    public static func boot(
        kernel: URL,
        store: URL,
        cpus: Int,
        memoryInBytes: UInt64,
        shares: [Share],
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
        try await process.start()
        let status = try await process.wait()
        try? await process.delete()
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
