"""write_atomic — durable, atomic file write for the filament mesh.

Protocol for every file write in bin/mesh-*:
  1. Write to <path>.tmp.<pid>  — isolates partial writes per-process
  2. fsync the file fd           — flush data to the OS page cache → disk
  3. os.replace(tmp, path)       — atomic rename (POSIX guarantee)
  4. fsync the parent directory  — make the rename itself durable (NFS/ext4)

Without step 4 the rename may be lost on a kernel crash even if the file
data is flushed. Without step 2 a power loss mid-write leaves a zero-byte
or truncated .tmp that, on the next run, silently passes the rename.

Stdlib-only. Python 3.8+.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path


def fsync_dir(directory: "Path | str") -> None:
    """fsync a directory so pending renames targeting it are durable."""
    _fsync_dir(Path(directory))


def write_atomic(
    path: "Path | str",
    content: str,
    encoding: str = "utf-8",
    add_checksum: bool = False,
) -> None:
    """Write *content* to *path* atomically and durably.

    If *add_checksum* is True, a ``CHECKSUM: sha256:<hex>`` line is injected
    immediately before the closing ``---`` of the frontmatter (if present),
    covering the body text.  Consumers can verify with
    :func:`verify_checksum`.

    Parameters
    ----------
    path:
        Destination file.  Parent directory must already exist.
    content:
        Text to write.
    encoding:
        Character encoding.  Defaults to UTF-8.
    add_checksum:
        If True and *content* has frontmatter, inject a CHECKSUM line.
    """
    path = Path(path)
    if add_checksum:
        content = _inject_checksum(content)

    data = content.encode(encoding)
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    try:
        with tmp.open("wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        _fsync_dir(path.parent)
    except BaseException:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _fsync_dir(directory: Path) -> None:
    """fsync the directory entry so the rename is durable (NFS/ext4 safety)."""
    try:
        fd = os.open(str(directory), os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass  # best-effort; some FSes (tmpfs) reject dir fsync


def _body_after_frontmatter(content: str) -> str:
    """Return the body portion of a frontmatter document, or the whole string."""
    parts = content.split("---\n", 2)
    return parts[2] if len(parts) >= 3 else content


def _inject_checksum(content: str) -> str:
    """Inject ``CHECKSUM: sha256:<hex>`` covering the body into frontmatter."""
    if not content.startswith("---"):
        return content
    # Find the closing --- of frontmatter (starts after the opening --- line)
    first_nl = content.index("\n")  # end of opening --- line
    rest = content[first_nl + 1:]   # everything after opening ---\n
    close_idx = rest.find("\n---")
    if close_idx == -1:
        return content  # malformed frontmatter; leave as-is
    # Remove any existing CHECKSUM line first (idempotent)
    fm_body = rest[:close_idx]
    fm_lines = [ln for ln in fm_body.splitlines() if not ln.startswith("CHECKSUM:")]
    body = rest[close_idx + 4:]  # after \n---
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    fm_lines.append(f"CHECKSUM: sha256:{digest}")
    return "---\n" + "\n".join(fm_lines) + "\n---" + body


def verify_checksum(content: str) -> bool | None:
    """Verify the CHECKSUM field in *content*.

    Returns:
        True   — checksum present and matches body
        False  — checksum present but does not match
        None   — no CHECKSUM field found
    """
    if not content.startswith("---"):
        return None
    first_nl = content.index("\n")
    rest = content[first_nl + 1:]
    close_idx = rest.find("\n---")
    if close_idx == -1:
        return None
    fm_body = rest[:close_idx]
    body = rest[close_idx + 4:]
    for line in fm_body.splitlines():
        if line.startswith("CHECKSUM: sha256:"):
            stored = line[len("CHECKSUM: sha256:"):]
            actual = hashlib.sha256(body.encode("utf-8")).hexdigest()
            return stored == actual
    return None
