//! Crash-safe report publication.

use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
};

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

use serde::Serialize;

use crate::MigrationError;

/// Failure-only audit record. It never includes error text, DSNs, or row data.
#[derive(Debug, Serialize)]
pub struct FailureAudit<'a> {
    pub status: &'static str,
    pub stage: &'a str,
    pub error_category: &'static str,
}

/// Serializes a report into a same-directory temporary file, fsyncs it, and
/// publishes it with an atomic rename. DSNs are absent from the report types.
pub fn write_atomic<T: Serialize>(path: &Path, report: &T) -> Result<(), MigrationError> {
    let parent = path.parent().ok_or_else(|| {
        MigrationError::Manifest("report path must have a parent directory".into())
    })?;
    fs::create_dir_all(parent)?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| MigrationError::Manifest("report filename is not valid UTF-8".into()))?;
    let temporary = parent.join(format!(".{file_name}.tmp-{}", std::process::id()));
    let result = (|| {
        reject_symlink_target(path)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = options.open(&temporary)?;
        #[cfg(unix)]
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        serde_json::to_writer_pretty(&mut file, report)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        drop(file);
        reject_symlink_target(path)?;
        fs::rename(&temporary, path)?;
        OpenOptions::new().read(true).open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn reject_symlink_target(path: &Path) -> Result<(), MigrationError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(MigrationError::Manifest(
            "report target must not be a symlink".into(),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    use std::os::unix::fs::{PermissionsExt, symlink};

    #[test]
    fn report_should_atomically_replace_existing_file() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("report.json");
        fs::write(&path, "old").unwrap();
        write_atomic(&path, &serde_json::json!({"status": "ok"})).unwrap();
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "{\n  \"status\": \"ok\"\n}\n"
        );
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[cfg(unix)]
    #[test]
    fn report_should_create_mode_0600_under_umask_022() {
        use std::process::Command;

        let directory = tempfile::tempdir().unwrap();
        let executable = std::env::current_exe().unwrap();
        let status = Command::new("sh")
            .args([
                "-c",
                "umask 022; exec \"$1\" --exact report::tests::report_umask_subprocess --ignored",
                "sh",
            ])
            .arg(&executable)
            .env("LMM_REPORT_UMASK_DIR", directory.path())
            .status()
            .unwrap();
        assert!(status.success());
        assert_eq!(
            fs::metadata(directory.path().join("report.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[cfg(unix)]
    #[test]
    #[ignore = "subprocess helper for the umask test"]
    fn report_umask_subprocess() {
        let directory = std::env::var_os("LMM_REPORT_UMASK_DIR").unwrap();
        write_atomic(
            &Path::new(&directory).join("report.json"),
            &serde_json::json!({"status": "ok"}),
        )
        .unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn report_should_reject_symlink_target_without_modifying_referent() {
        let directory = tempfile::tempdir().unwrap();
        let referent = directory.path().join("referent.json");
        fs::write(&referent, "unchanged").unwrap();
        let target = directory.path().join("report.json");
        symlink(&referent, &target).unwrap();

        assert!(write_atomic(&target, &serde_json::json!({"status": "ok"})).is_err());
        assert_eq!(fs::read_to_string(referent).unwrap(), "unchanged");
    }
}
