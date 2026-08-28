use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Component as PathComponent, Path, PathBuf},
    process::Command,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use futures_util::StreamExt;
use minisign_verify::{PublicKey, Signature};
use reqwest::{Client, Url, redirect::Policy};
use serde::Deserialize;
use thiserror::Error;

const MANIFEST_URL: &str = "https://dl.ccswitch.io/latest.json";
const PUBLIC_KEY: &str = "untrusted comment: minisign public key: C8028C9A573928E3\nRWTjKDlXmowCyC9Q/dOAftdyN/oC70kgS2Zbl5CRd63EFO5NZwtHjEVQ\n";
const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
const MAX_ASSET_BYTES: u64 = 192 * 1024 * 1024;
const MAX_ARCHIVE_ENTRIES: usize = 10_000;
const MAX_REDIRECTS: usize = 5;

#[derive(Debug, Error)]
pub enum ReleaseError {
    #[error("unsupported CC Switch release target: {platform}/{architecture}")]
    UnsupportedTarget {
        platform: &'static str,
        architecture: &'static str,
    },
    #[error("build CC Switch HTTP client: {0}")]
    HttpClient(String),
    #[error("download CC Switch release metadata or asset: {0}")]
    Download(String),
    #[error("CC Switch download returned HTTP {0}")]
    HttpStatus(u16),
    #[error("CC Switch download exceeded its {limit}-byte limit")]
    DownloadTooLarge { limit: u64 },
    #[error("invalid CC Switch updater manifest: {0}")]
    InvalidManifest(String),
    #[error("CC Switch updater selected an unsafe asset URL: {0}")]
    UnsafeAssetUrl(String),
    #[error("CC Switch release signature is invalid: {0}")]
    InvalidSignature(String),
    #[error("create CC Switch temporary path: {0}")]
    CreateTemp(String),
    #[error("write CC Switch temporary asset: {0}")]
    WriteTemp(String),
    #[error("CC Switch install destination is unsafe: {0}")]
    UnsafeDestination(String),
    #[error("failed to start {program}: {message}")]
    StartFailed { program: String, message: String },
    #[error("{program} exited unsuccessfully with status {status}")]
    CommandFailed { program: String, status: String },
}

#[derive(Debug, Deserialize)]
struct UpdaterManifest {
    version: String,
    platforms: HashMap<String, UpdaterAsset>,
}

#[derive(Debug, Deserialize)]
struct UpdaterAsset {
    signature: String,
    url: String,
}

pub fn validate_action(repository: &str) -> Result<(), ReleaseError> {
    if repository == "farion1231/cc-switch" {
        Ok(())
    } else {
        Err(ReleaseError::InvalidManifest(format!(
            "unapproved repository {repository}"
        )))
    }
}

pub async fn install() -> Result<(), ReleaseError> {
    let (platform_key, temporary_asset) = download_release().await?;
    match platform_key {
        "linux-x86_64" | "linux-aarch64" => install_linux_appimage(temporary_asset.path()),
        "darwin-x86_64" | "darwin-aarch64" => install_macos_archive(temporary_asset.path()),
        "windows-x86_64" | "windows-aarch64" => install_windows_msi(temporary_asset.path()),
        _ => Err(ReleaseError::UnsupportedTarget {
            platform: std::env::consts::OS,
            architecture: std::env::consts::ARCH,
        }),
    }
}

async fn download_release() -> Result<(&'static str, TemporaryPath), ReleaseError> {
    let platform_key = platform_key(std::env::consts::OS, std::env::consts::ARCH)?;
    let client = http_client()?;
    let manifest_bytes = fetch_limited(&client, MANIFEST_URL, MAX_MANIFEST_BYTES).await?;
    let mut manifest: UpdaterManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|error| ReleaseError::InvalidManifest(error.to_string()))?;
    validate_version(&manifest.version)?;
    let asset = manifest.platforms.remove(platform_key).ok_or_else(|| {
        ReleaseError::InvalidManifest(format!("platform {platform_key} is absent"))
    })?;
    let asset_url = validate_asset_url(&manifest.version, platform_key, &asset.url)?;
    let signature = decode_signature(&asset.signature)?;
    let public_key = PublicKey::decode(PUBLIC_KEY)
        .map_err(|error| ReleaseError::InvalidSignature(error.to_string()))?;
    let extension = asset_extension(platform_key);
    let (asset_file, temporary_asset) = create_temp_file(extension)?;
    download_verified(&client, asset_url, asset_file, &public_key, &signature).await?;
    Ok((platform_key, temporary_asset))
}

fn http_client() -> Result<Client, ReleaseError> {
    Client::builder()
        .user_agent(concat!("lmm-api-rs/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(10 * 60))
        .redirect(Policy::custom(|attempt| {
            if attempt.previous().len() >= MAX_REDIRECTS || attempt.url().scheme() != "https" {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .build()
        .map_err(|error| ReleaseError::HttpClient(error.to_string()))
}

async fn fetch_limited(client: &Client, url: &str, limit: u64) -> Result<Vec<u8>, ReleaseError> {
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|error| ReleaseError::Download(error.to_string()))?;
    if !response.status().is_success() {
        return Err(ReleaseError::HttpStatus(response.status().as_u16()));
    }
    if response.url().as_str() != url {
        return Err(ReleaseError::UnsafeAssetUrl(response.url().to_string()));
    }
    if response
        .content_length()
        .is_some_and(|length| length > limit)
    {
        return Err(ReleaseError::DownloadTooLarge { limit });
    }

    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| ReleaseError::Download(error.to_string()))?;
        if (bytes.len() as u64).saturating_add(chunk.len() as u64) > limit {
            return Err(ReleaseError::DownloadTooLarge { limit });
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn download_verified(
    client: &Client,
    url: Url,
    mut destination: File,
    public_key: &PublicKey,
    signature: &Signature,
) -> Result<(), ReleaseError> {
    let response = client
        .get(url.clone())
        .send()
        .await
        .map_err(|error| ReleaseError::Download(error.to_string()))?;
    if !response.status().is_success() {
        return Err(ReleaseError::HttpStatus(response.status().as_u16()));
    }
    if response.url() != &url {
        return Err(ReleaseError::UnsafeAssetUrl(response.url().to_string()));
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_ASSET_BYTES)
    {
        return Err(ReleaseError::DownloadTooLarge {
            limit: MAX_ASSET_BYTES,
        });
    }

    let mut verifier = public_key
        .verify_stream(signature)
        .map_err(|error| ReleaseError::InvalidSignature(error.to_string()))?;
    let mut downloaded = 0_u64;
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| ReleaseError::Download(error.to_string()))?;
        downloaded = downloaded.saturating_add(chunk.len() as u64);
        if downloaded > MAX_ASSET_BYTES {
            return Err(ReleaseError::DownloadTooLarge {
                limit: MAX_ASSET_BYTES,
            });
        }
        verifier.update(&chunk);
        destination
            .write_all(&chunk)
            .map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    }
    destination
        .sync_all()
        .map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    verifier
        .finalize()
        .map_err(|error| ReleaseError::InvalidSignature(error.to_string()))
}

fn platform_key(
    platform: &'static str,
    architecture: &'static str,
) -> Result<&'static str, ReleaseError> {
    match (platform, architecture) {
        ("linux", "x86_64") => Ok("linux-x86_64"),
        ("linux", "aarch64") => Ok("linux-aarch64"),
        ("macos", "x86_64") => Ok("darwin-x86_64"),
        ("macos", "aarch64") => Ok("darwin-aarch64"),
        ("windows", "x86_64") => Ok("windows-x86_64"),
        ("windows", "aarch64") => Ok("windows-aarch64"),
        _ => Err(ReleaseError::UnsupportedTarget {
            platform,
            architecture,
        }),
    }
}

fn validate_version(version: &str) -> Result<(), ReleaseError> {
    let valid = !version.is_empty()
        && version.len() <= 64
        && version.starts_with(|character: char| character.is_ascii_digit())
        && version
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '-'));
    if valid {
        Ok(())
    } else {
        Err(ReleaseError::InvalidManifest(
            "version is not a safe release identifier".to_owned(),
        ))
    }
}

fn validate_asset_url(version: &str, platform: &str, value: &str) -> Result<Url, ReleaseError> {
    let url = Url::parse(value).map_err(|error| ReleaseError::UnsafeAssetUrl(error.to_string()))?;
    let expected_suffix = match platform {
        "linux-x86_64" => "-Linux-x86_64.AppImage",
        "linux-aarch64" => "-Linux-arm64.AppImage",
        "darwin-x86_64" | "darwin-aarch64" => "-macOS.tar.gz",
        "windows-x86_64" => "-Windows.msi",
        "windows-aarch64" => "-Windows-arm64.msi",
        _ => return Err(ReleaseError::UnsafeAssetUrl(value.to_owned())),
    };
    let expected_prefix = format!("/v{version}/CC-Switch-v{version}");
    let safe = url.scheme() == "https"
        && url.host_str() == Some("dl.ccswitch.io")
        && url.port().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && url.path() == format!("{expected_prefix}{expected_suffix}");
    if safe {
        Ok(url)
    } else {
        Err(ReleaseError::UnsafeAssetUrl(value.to_owned()))
    }
}

fn asset_extension(platform: &str) -> &'static str {
    if platform.starts_with("linux-") {
        "AppImage"
    } else if platform.starts_with("darwin-") {
        "tar.gz"
    } else {
        "msi"
    }
}

fn decode_signature(encoded: &str) -> Result<Signature, ReleaseError> {
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|error| ReleaseError::InvalidSignature(error.to_string()))?;
    let text = std::str::from_utf8(&bytes)
        .map_err(|error| ReleaseError::InvalidSignature(error.to_string()))?;
    Signature::decode(text).map_err(|error| ReleaseError::InvalidSignature(error.to_string()))
}

fn install_linux_appimage(asset: &Path) -> Result<(), ReleaseError> {
    let home = home_directory()?;
    let bin_directory = home.join(".local/bin");
    ensure_safe_directory(&bin_directory)?;
    let destination = bin_directory.join("cc-switch");
    ensure_safe_replace_target(&destination)?;
    let staging = bin_directory.join(format!(".cc-switch.install-{}", std::process::id()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    let mut output = options
        .open(&staging)
        .map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    let staging_guard = TemporaryPath(staging.clone());
    let mut input =
        File::open(asset).map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    std::io::copy(&mut input, &mut output)
        .map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    output
        .sync_all()
        .map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    make_executable(&staging)?;
    fs::rename(&staging, &destination)
        .map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    drop(staging_guard);
    println!("Installed CC Switch AppImage at {}", destination.display());
    Ok(())
}

fn install_macos_archive(asset: &Path) -> Result<(), ReleaseError> {
    let listing = command_output("tar", &["-tzf", &asset.to_string_lossy()])?;
    validate_archive_listing(&listing)?;
    let extraction = TemporaryDirectory::create("cc-switch-extract")?;
    run_status(
        "tar",
        &[
            "-xzf".to_owned(),
            asset.to_string_lossy().into_owned(),
            "-C".to_owned(),
            extraction.path().to_string_lossy().into_owned(),
        ],
    )?;
    let source = extraction.path().join("CC Switch.app");
    if !source.is_dir() || source.is_symlink() {
        return Err(ReleaseError::UnsafeDestination(
            "signed archive does not contain CC Switch.app".to_owned(),
        ));
    }

    let applications = home_directory()?.join("Applications");
    ensure_safe_directory(&applications)?;
    let destination = applications.join("CC Switch.app");
    if destination.exists() || destination.is_symlink() {
        return Err(ReleaseError::UnsafeDestination(format!(
            "{} already exists; update it through CC Switch or Homebrew",
            destination.display()
        )));
    }
    run_status(
        "ditto",
        &[
            source.to_string_lossy().into_owned(),
            destination.to_string_lossy().into_owned(),
        ],
    )?;
    let mut installed_guard = InstalledDirectory::new(destination.clone());
    run_status(
        "codesign",
        &[
            "--verify".to_owned(),
            "--deep".to_owned(),
            "--strict".to_owned(),
            destination.to_string_lossy().into_owned(),
        ],
    )?;
    run_status(
        "spctl",
        &[
            "--assess".to_owned(),
            "--type".to_owned(),
            "execute".to_owned(),
            destination.to_string_lossy().into_owned(),
        ],
    )?;
    installed_guard.disarm();
    println!("Installed CC Switch at {}", destination.display());
    Ok(())
}

fn install_windows_msi(asset: &Path) -> Result<(), ReleaseError> {
    run_status(
        "msiexec.exe",
        &["/i".to_owned(), asset.to_string_lossy().into_owned()],
    )
}

fn validate_archive_listing(listing: &str) -> Result<(), ReleaseError> {
    let mut entries = 0_usize;
    for line in listing.lines() {
        entries += 1;
        if entries > MAX_ARCHIVE_ENTRIES {
            return Err(ReleaseError::UnsafeDestination(
                "archive contains too many entries".to_owned(),
            ));
        }
        let mut components = Path::new(line)
            .components()
            .filter(|component| !matches!(component, PathComponent::CurDir));
        if components.next() != Some(PathComponent::Normal("CC Switch.app".as_ref()))
            || components.any(|component| {
                matches!(
                    component,
                    PathComponent::ParentDir | PathComponent::RootDir | PathComponent::Prefix(_)
                )
            })
        {
            return Err(ReleaseError::UnsafeDestination(format!(
                "unsafe archive entry {line}"
            )));
        }
    }
    if entries == 0 {
        return Err(ReleaseError::UnsafeDestination(
            "archive is empty".to_owned(),
        ));
    }
    Ok(())
}

fn command_output(program: &str, arguments: &[&str]) -> Result<String, ReleaseError> {
    let output = Command::new(program)
        .args(arguments)
        .output()
        .map_err(|error| ReleaseError::StartFailed {
            program: program.to_owned(),
            message: error.to_string(),
        })?;
    if !output.status.success() {
        return Err(ReleaseError::CommandFailed {
            program: program.to_owned(),
            status: output.status.to_string(),
        });
    }
    String::from_utf8(output.stdout)
        .map_err(|error| ReleaseError::UnsafeDestination(error.to_string()))
}

fn run_status(program: &str, arguments: &[String]) -> Result<(), ReleaseError> {
    let status = Command::new(program)
        .args(arguments)
        .status()
        .map_err(|error| ReleaseError::StartFailed {
            program: program.to_owned(),
            message: error.to_string(),
        })?;
    if status.success() {
        Ok(())
    } else {
        Err(ReleaseError::CommandFailed {
            program: program.to_owned(),
            status: status.to_string(),
        })
    }
}

fn home_directory() -> Result<PathBuf, ReleaseError> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| ReleaseError::UnsafeDestination("home directory is unavailable".to_owned()))
}

fn ensure_safe_directory(path: &Path) -> Result<(), ReleaseError> {
    if path.exists() {
        let metadata = fs::symlink_metadata(path)
            .map_err(|error| ReleaseError::UnsafeDestination(error.to_string()))?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(ReleaseError::UnsafeDestination(path.display().to_string()));
        }
    } else {
        fs::create_dir_all(path)
            .map_err(|error| ReleaseError::UnsafeDestination(error.to_string()))?;
    }
    Ok(())
}

fn ensure_safe_replace_target(path: &Path) -> Result<(), ReleaseError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => Ok(()),
        Ok(_) => Err(ReleaseError::UnsafeDestination(path.display().to_string())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ReleaseError::UnsafeDestination(error.to_string())),
    }
}

fn create_temp_file(extension: &str) -> Result<(File, TemporaryPath), ReleaseError> {
    let timestamp = timestamp();
    for attempt in 0..8_u8 {
        let path = std::env::temp_dir().join(format!(
            "lmm-api-rs-cc-switch-{}-{timestamp}-{attempt}.{extension}",
            std::process::id()
        ));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => return Ok((file, TemporaryPath(path))),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(ReleaseError::CreateTemp(error.to_string())),
        }
    }
    Err(ReleaseError::CreateTemp(
        "could not allocate a unique file".to_owned(),
    ))
}

fn make_executable(path: &Path) -> Result<(), ReleaseError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(path, fs::Permissions::from_mode(0o755))
            .map_err(|error| ReleaseError::WriteTemp(error.to_string()))?;
    }
    Ok(())
}

fn timestamp() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos())
}

struct TemporaryPath(PathBuf);

impl TemporaryPath {
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TemporaryPath {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

struct TemporaryDirectory(PathBuf);

impl TemporaryDirectory {
    fn create(label: &str) -> Result<Self, ReleaseError> {
        for attempt in 0..8_u8 {
            let path = std::env::temp_dir().join(format!(
                "lmm-api-rs-{label}-{}-{}-{attempt}",
                std::process::id(),
                timestamp()
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(ReleaseError::CreateTemp(error.to_string())),
            }
        }
        Err(ReleaseError::CreateTemp(
            "could not allocate a unique directory".to_owned(),
        ))
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TemporaryDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct InstalledDirectory {
    path: PathBuf,
    armed: bool,
}

impl InstalledDirectory {
    fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for InstalledDirectory {
    fn drop(&mut self) {
        if self.armed && self.path.is_dir() && !self.path.is_symlink() {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ReleaseError, download_release, platform_key, validate_archive_listing, validate_asset_url,
        validate_version,
    };

    #[test]
    fn platform_keys_cover_supported_release_targets() -> Result<(), ReleaseError> {
        assert_eq!(platform_key("linux", "x86_64")?, "linux-x86_64");
        assert_eq!(platform_key("macos", "aarch64")?, "darwin-aarch64");
        assert_eq!(platform_key("windows", "x86_64")?, "windows-x86_64");
        Ok(())
    }

    #[test]
    fn unsupported_architecture_is_rejected() {
        assert!(matches!(
            platform_key("linux", "riscv64"),
            Err(ReleaseError::UnsupportedTarget { .. })
        ));
    }

    #[test]
    fn asset_url_is_bound_to_version_platform_and_origin() {
        let valid = "https://dl.ccswitch.io/v3.20.1/CC-Switch-v3.20.1-Linux-x86_64.AppImage";
        assert!(validate_asset_url("3.20.1", "linux-x86_64", valid).is_ok());
        assert!(
            validate_asset_url(
                "3.20.1",
                "linux-x86_64",
                "https://example.com/v3.20.1/CC-Switch-v3.20.1-Linux-x86_64.AppImage"
            )
            .is_err()
        );
    }

    #[test]
    fn version_rejects_path_control_characters() {
        assert!(validate_version("3.20.1").is_ok());
        assert!(validate_version("../3.20.1").is_err());
        assert!(validate_version("3.20.1?next").is_err());
    }

    #[tokio::test]
    #[ignore = "requires the live signed CC Switch release service"]
    async fn live_release_download_passes_minisign_verification() -> Result<(), ReleaseError> {
        let (_platform, asset) = download_release().await?;
        assert!(asset.path().is_file());
        Ok(())
    }

    #[test]
    fn macos_archive_listing_stays_inside_application_bundle() {
        assert!(
            validate_archive_listing("CC Switch.app/\nCC Switch.app/Contents/MacOS/cc-switch\n")
                .is_ok()
        );
        assert!(validate_archive_listing("CC Switch.app/../../escape\n").is_err());
        assert!(validate_archive_listing("other/CC Switch.app\n").is_err());
    }
}
