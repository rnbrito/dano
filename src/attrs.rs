//       ___           ___           ___           ___
//      /\  \         /\  \         /\__\         /\  \
//     /::\  \       /::\  \       /::|  |       /::\  \
//    /:/\:\  \     /:/\:\  \     /:|:|  |      /:/\:\  \
//   /:/  \:\__\   /::\~\:\  \   /:/|:|  |__   /:/  \:\  \
//  /:/__/ \:|__| /:/\:\ \:\__\ /:/ |:| /\__\ /:/__/ \:\__\
//  \:\  \ /:/  / \/__\:\/:/  / \/__|:|/:/  / \:\  \ /:/  /
//   \:\  /:/  /       \::/  /      |:/:/  /   \:\  /:/  /
//    \:\/:/  /        /:/  /       |::/  /     \:\/:/  /
//     \::/__/        /:/  /        /:/  /       \::/  /
//      ~~            \/__/         \/__/         \/__/
//
// (c) Robert Swinford <robert.swinford<...at...>gmail.com>
//
// For the full copyright and license information, please view the LICENSE file
// that was distributed with this source code.

// Platform abstraction for storing dano's per-file checksum alongside the file.
//
// * Unix-like systems: extended attributes (xattrs), as before.
// * Windows: NTFS Alternate Data Streams (ADS), e.g. "movie.mkv:user.dano.checksum".
//   ADS are the closest Windows equivalent of xattrs: they travel with the file
//   on NTFS volumes and are invisible to ordinary file listings.  Volumes which
//   do not support ADS (FAT32, exFAT, many network shares) will return an error,
//   just as filesystems without xattr support do on Unix.

use std::io;
use std::path::Path;

#[cfg(unix)]
mod imp {
    use super::*;

    pub fn get(path: &Path, name: &str) -> io::Result<Option<Vec<u8>>> {
        xattr::get(path, name)
    }

    pub fn set(path: &Path, name: &str, value: &[u8]) -> io::Result<()> {
        let _ = xattr::remove(path, name);
        xattr::set(path, name, value)
    }

    pub fn remove(path: &Path, name: &str) -> io::Result<()> {
        xattr::remove(path, name)
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::ffi::OsString;
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Write};
    use std::path::PathBuf;
    use std::time::SystemTime;

    fn stream_path(path: &Path, name: &str) -> PathBuf {
        let mut os: OsString = path.as_os_str().to_owned();
        os.push(":");
        os.push(name);
        PathBuf::from(os)
    }

    // Writing to (or deleting) an ADS updates the parent file's last write time on
    // NTFS.  dano records the modify time of files, and other tools (backup, sync)
    // rely on it, so we restore the original modify time afterwards.
    fn with_preserved_mtime<T>(path: &Path, f: impl FnOnce() -> io::Result<T>) -> io::Result<T> {
        let opt_mtime: Option<SystemTime> = path.metadata().and_then(|md| md.modified()).ok();

        let res = f()?;

        if let Some(mtime) = opt_mtime {
            if let Ok(file) = OpenOptions::new().write(true).open(path) {
                let _ = file.set_modified(mtime);
            }
        }

        Ok(res)
    }

    pub fn get(path: &Path, name: &str) -> io::Result<Option<Vec<u8>>> {
        // make sure the base file exists, so a missing file is reported as such
        // and not silently treated as "no attribute"
        let _ = path.metadata()?;

        match File::open(stream_path(path, name)) {
            Ok(mut file) => {
                let mut buf = Vec::new();
                file.read_to_end(&mut buf)?;
                Ok(Some(buf))
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err),
        }
    }

    pub fn set(path: &Path, name: &str, value: &[u8]) -> io::Result<()> {
        let _ = path.metadata()?;

        with_preserved_mtime(path, || {
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(stream_path(path, name))?;
            file.write_all(value)?;
            file.flush()
        })
    }

    pub fn remove(path: &Path, name: &str) -> io::Result<()> {
        let _ = path.metadata()?;

        if get(path, name)?.is_none() {
            return Err(no_data());
        }

        with_preserved_mtime(path, || std::fs::remove_file(stream_path(path, name)))
    }

    // mirror the ENODATA error Linux returns when removing a non-existent xattr
    fn no_data() -> io::Error {
        io::Error::new(io::ErrorKind::NotFound, "No data available")
    }
}

#[cfg(not(any(unix, windows)))]
mod imp {
    use super::*;

    fn unsupported() -> io::Error {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "Extended attributes are not supported on this platform",
        )
    }

    pub fn get(_path: &Path, _name: &str) -> io::Result<Option<Vec<u8>>> {
        Ok(None)
    }

    pub fn set(_path: &Path, _name: &str, _value: &[u8]) -> io::Result<()> {
        Err(unsupported())
    }

    pub fn remove(_path: &Path, _name: &str) -> io::Result<()> {
        Err(unsupported())
    }
}

pub use imp::{get, remove, set};
