using System.Runtime.InteropServices;

namespace Nixploy.Cli;

public sealed record AgeIdentityFileMetadata(
    string FullPath,
    bool Exists,
    bool IsRegularFile,
    bool HasSymlinkComponent,
    bool IsReadable,
    uint OwnerUserId,
    UnixFileMode Mode
)
{
    public static AgeIdentityFileMetadata Inspect(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var info = new FileInfo(fullPath);
        var exists = info.Exists;
        var hasSymlink = exists && HasSymlink(fullPath);
        var readable = exists && !hasSymlink && CanOpenForRead(fullPath);

        if (OperatingSystem.IsWindows())
        {
            return new AgeIdentityFileMetadata(
                fullPath,
                exists,
                exists && !info.Attributes.HasFlag(FileAttributes.Directory),
                hasSymlink,
                readable,
                0,
                0
            );
        }

        var mode = exists ? File.GetUnixFileMode(fullPath) : 0;
        var stat = exists ? ReadLinuxStat(fullPath) : null;

        return new AgeIdentityFileMetadata(
            fullPath,
            exists,
            stat is { IsRegularFile: true },
            hasSymlink,
            readable,
            stat?.OwnerUserId ?? uint.MaxValue,
            mode
        );
    }

    private static bool CanOpenForRead(string path)
    {
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                1,
                FileOptions.None
            );
            return stream.CanRead;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        catch (IOException)
        {
            return false;
        }
    }

    private static bool HasSymlink(string fullPath)
    {
        var root = Path.GetPathRoot(fullPath)!;
        var current = root;
        var parts = fullPath[root.Length..]
            .Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);

        for (var index = 0; index < parts.Length; index++)
        {
            current = Path.Combine(current, parts[index]);
            FileSystemInfo component = index == parts.Length - 1
                ? new FileInfo(current)
                : new DirectoryInfo(current);

            if (component.LinkTarget is not null)
            {
                return true;
            }
        }

        return false;
    }

    private static LinuxStat? ReadLinuxStat(string path)
    {
        if (!OperatingSystem.IsLinux())
        {
            return null;
        }

        var buffer = new byte[256];
        var handle = GCHandle.Alloc(buffer, GCHandleType.Pinned);

        try
        {
            const int atFileWorkingDirectory = -100;
            const int atSymlinkNoFollow = 0x100;
            const uint requestedFields = 0x0b; // type, mode, and uid

            if (Statx(
                    atFileWorkingDirectory,
                    path,
                    atSymlinkNoFollow,
                    requestedFields,
                    handle.AddrOfPinnedObject()
                ) != 0)
            {
                return null;
            }

            var ownerUserId = BitConverter.ToUInt32(buffer, 20);
            var nativeMode = BitConverter.ToUInt16(buffer, 28);
            const ushort fileTypeMask = 0xf000;
            const ushort regularFile = 0x8000;

            return new LinuxStat(ownerUserId, (nativeMode & fileTypeMask) == regularFile);
        }
        finally
        {
            handle.Free();
        }
    }

    [DllImport("libc", SetLastError = true, EntryPoint = "statx")]
    private static extern int Statx(
        int directoryFileDescriptor,
        string path,
        int flags,
        uint mask,
        IntPtr buffer
    );

    private sealed record LinuxStat(uint OwnerUserId, bool IsRegularFile);
}
