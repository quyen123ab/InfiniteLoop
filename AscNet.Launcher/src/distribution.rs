use crate::local::{self, LocalBuild};
use anyhow::{ensure, Context, Result};
use serde::Deserialize;
use std::{env, fs, path::{Path, PathBuf}};

pub const PAIRED: bool = cfg!(feature = "pgr49-distribution");
pub(crate) const REPOSITORY: &str = "https://github.com/quyen123ab/InfiniteLoop.git";
const BRANCH: &str = "integration/pgr49-gmtools";

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LauncherConfig {
    repository_url: String,
    branch: String,
    #[serde(default)]
    bundled_local_server: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseManifest {
    schema_version: u32,
    repository: String,
    branch: String,
    commit: String,
}

#[derive(Deserialize)]
struct ActiveRelease {
    #[serde(rename = "schemaVersion")]
    schema_version: u32,
    current: String,
}

#[derive(Deserialize)]
struct LaunchTarget {
    #[serde(flatten)]
    release: ReleaseManifest,
    version: String,
    files: std::collections::BTreeMap<String, String>,
}

/// The copy placed at the original launcher path delegates to the active release.
/// An executable shipped inside a release always runs its own matching payload.
pub fn active_launcher(directory: &Path) -> Result<Option<PathBuf>> {
    if !PAIRED || directory.join("release.json").is_file() {
        return Ok(None);
    }
    let install = directory.join("InfiniteLoop-Pgr49");
    let state_path = install.join("active.json");
    let bytes = match fs::read(&state_path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).context("read active PGR 4.9 release"),
    };
    let state: ActiveRelease = serde_json::from_slice(&bytes).context("invalid active PGR 4.9 release")?;
    ensure!(state.schema_version == 1, "unsupported PGR 4.9 deployment state");
    ensure!(state.current.starts_with("InfiniteLoop-") && state.current.ends_with("-win-x64")
        && state.current.bytes().all(|byte| byte.is_ascii_alphanumeric() || b".-".contains(&byte)),
        "invalid active release directory");
    let release_directory = install.join("versions").join(&state.current);
    let launcher = release_directory.join("AscNetLauncher.exe");
    ensure!(launcher.canonicalize()? == directory.canonicalize()?.join("InfiniteLoop-Pgr49")
        .join("versions").join(&state.current).join("AscNetLauncher.exe"),
        "active PGR 4.9 launcher resolves outside its release directory");
    let target: LaunchTarget = serde_json::from_slice(&fs::read(release_directory.join("release.json"))?)
        .context("read active PGR 4.9 release manifest")?;
    target.release.validate()?;
    let id = format!("InfiniteLoop-{}-{}-win-x64", target.version, &target.release.commit[..12]);
    ensure!(state.current == id, "active PGR 4.9 release identity differs from deployment state");
    let expected = target.files.get("AscNetLauncher.exe").context("no launcher hash in active release")?;
    ensure!(&crate::package::sha256_file(&launcher)? == expected, "active PGR 4.9 launcher SHA-256 mismatch");
    Ok(Some(launcher))
}

#[derive(Clone)]
pub struct Distribution {
    config: LauncherConfig,
    pub release: Option<Release>,
}

#[derive(Clone)]
pub struct Release {
    pub(crate) directory: PathBuf,
    pub(crate) commit: String,
}

impl Distribution {
    pub fn load(directory: &Path) -> Result<Self> {
        let config: LauncherConfig = serde_json::from_slice(
            &fs::read(directory.join("launcher.json")).context("launcher.json is missing")?,
        ).context("launcher.json is invalid")?;
        let release = if PAIRED {
            ensure!(config.bundled_local_server && config.repository_url == REPOSITORY && config.branch == BRANCH,
                "This launcher requires the PGR 4.9 distribution configuration and its canonical fork branch");
            Some(Release::load(directory, option_env!("ASCNET_RELEASE_COMMIT"))?)
        } else {
            ensure!(!config.bundled_local_server, "Build the launcher with the pgr49-distribution feature for paired releases");
            None
        };
        Ok(Self { config, release })
    }

    pub fn repository(&self) -> &str { &self.config.repository_url }

    pub fn load_build(&self) -> Result<Option<LocalBuild>> {
        match &self.release {
            Some(release) => local::load_paired_build(release),
            None => local::load_build(),
        }
    }

    pub fn prepare(&self, game: &Path, progress: &mut dyn FnMut(&str)) -> Result<LocalBuild> {
        match &self.release {
            Some(release) => local::prepare_paired(release, game, progress),
            None => local::prepare(&self.config.repository_url, &self.config.branch, game, progress),
        }
    }

    pub fn check_source_update(&self, build: Option<&LocalBuild>) -> Result<Option<bool>> {
        if self.release.is_some() { return Ok(None); }
        local::check_update(&self.config.repository_url, &self.config.branch, build)
    }

    pub fn mod_roots(&self, local_root: &Path) -> Vec<PathBuf> {
        let legacy = crate::setup::mods_directory(local_root);
        match &self.release {
            Some(release) => vec![release.directory.join("Mods"), local_root.join("Mods"), legacy],
            None => vec![legacy],
        }
    }
}

impl Release {
    fn load(directory: &Path, expected_commit: Option<&str>) -> Result<Self> {
        let manifest: ReleaseManifest = serde_json::from_slice(
            &fs::read(directory.join("release.json")).context("Extract the complete PGR 4.9 release, including release.json")?,
        ).context("release.json is invalid")?;
        manifest.validate()?;
        ensure!(Some(manifest.commit.as_str()) == expected_commit,
            "The launcher and release.json do not come from the same build");
        for required in [
            "server/AscNet.dll", "server/Configs/version_config.json", "server/Configs/config.json",
            "Mods/gm-menu/mod.json", "Mods/gm-menu/XAscNet/XAscNetGmPanel.lua",
            "Mods/gm-menu/XManager/XGmTestManager.diff", "Mods/core/mod.json",
        ] {
            ensure!(directory.join(required).is_file(), "Paired release is missing {required}");
        }
        crate::package::load_package(&directory.join("patch")).context("validate bundled client patch")?;
        let commit_marker = format!("+{}", manifest.commit);
        let dll = fs::read(directory.join("server/AscNet.dll")).context("read bundled server identity")?;
        ensure!(dll.windows(commit_marker.len()).any(|bytes| bytes == commit_marker.as_bytes()),
            "The bundled server and launcher do not come from the same build");
        Ok(Self { directory: directory.to_path_buf(), commit: manifest.commit })
    }
}

impl ReleaseManifest {
    fn validate(&self) -> Result<()> {
        ensure!(self.schema_version == 1 && self.repository == REPOSITORY && self.branch == BRANCH,
            "release.json does not describe the PGR 4.9 custom distribution");
        ensure!(self.commit.len() == 40 && self.commit.bytes().all(|byte| byte.is_ascii_hexdigit()),
            "release.json has an invalid source commit");
        Ok(())
    }
}

// Transitions between verified paired releases can include a native patch downgrade.
// The normal installer still verifies the prior state, original files and backups.
pub(crate) fn owns_patch(directory: &Path) -> bool {
    if !PAIRED { return false; }
    (|| -> Result<bool> {
        let exe = env::current_exe()?;
        let distribution = Distribution::load(exe.parent().context("launcher directory missing")?)?;
        let release = distribution.release.context("paired release missing")?;
        Ok(directory.canonicalize()? == release.directory.join("patch").canonicalize()?)
    })().unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(feature = "pgr49-distribution")]
    fn custom_launcher_cannot_load_stock_setup_configuration() {
        let root = env::temp_dir().join(format!("ascnet-distribution-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("launcher.json"), r#"{"repositoryUrl":"https://github.com/reiserFSs/InfiniteLoop.git","branch":"master"}"#).unwrap();
        let result = Distribution::load(&root);
        fs::remove_dir_all(root).unwrap();
        assert!(result.err().unwrap().to_string().contains("canonical fork branch"));
    }

    #[test]
    #[cfg(feature = "pgr49-distribution")]
    fn original_entry_point_follows_the_verified_active_release() -> Result<()> {
        let root = env::temp_dir().join(format!("ascnet-entry-point-{}", uuid::Uuid::new_v4()));
        let commit = "1234567890123456789012345678901234567890";
        let version = "1.0.24-pgr49.1";
        let id = "InfiniteLoop-1.0.24-pgr49.1-123456789012-win-x64";
        let install = root.join("InfiniteLoop-Pgr49");
        let release = install.join("versions").join(id);
        fs::create_dir_all(&release)?;
        let result = (|| -> Result<()> {
            fs::write(install.join("active.json"), serde_json::to_vec(&serde_json::json!({
                "schemaVersion": 1, "current": id, "previous": ""
            }))?)?;
            let launcher = release.join("AscNetLauncher.exe");
            fs::write(&launcher, b"fixture")?;
            let hash = crate::package::sha256_file(&launcher)?;
            fs::write(release.join("release.json"), serde_json::to_vec(&serde_json::json!({
                "schemaVersion": 1, "commit": commit, "repository": REPOSITORY, "branch": BRANCH,
                "version": version, "files": { "AscNetLauncher.exe": hash }
            }))?)?;
            assert_eq!(active_launcher(&root)?, Some(launcher.clone()));
            assert_eq!(active_launcher(&release)?, None);
            fs::write(launcher, b"changed")?;
            assert!(active_launcher(&root).unwrap_err().to_string().contains("SHA-256 mismatch"));
            Ok(())
        })();
        fs::remove_dir_all(root)?;
        result
    }
}
