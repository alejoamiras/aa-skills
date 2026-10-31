// strerror(3)'s words for what a read or a write can fail with, as Python's OSError carries them
export const STRERROR: Record<string, string> = {
  ENOENT: "No such file or directory", EACCES: "Permission denied", EISDIR: "Is a directory", ENOTDIR: "Not a directory",
  ELOOP: "Too many levels of symbolic links", ENAMETOOLONG: "File name too long", EIO: "Input/output error",
  ENXIO: "No such device or address", EMFILE: "Too many open files", ENFILE: "Too many open files in system",
  ENOMEM: "Cannot allocate memory", EPERM: "Operation not permitted", EINVAL: "Invalid argument",
  ENOSPC: "No space left on device", EPIPE: "Broken pipe", EFBIG: "File too large", EDQUOT: "Disk quota exceeded",
};

/** The last line of Python's report of a failed system call, e.g. "OSError: [Errno 28] No space left on device". */
export function pyOSError(e: unknown): string {
  const { code = "", errno = 0 } = e as { code?: string; errno?: number };
  return `${code === "EPIPE" ? "BrokenPipeError" : "OSError"}: [Errno ${Math.abs(errno)}] ${STRERROR[code] ?? code}`;
}
