use std::{
    fs,
    io::{self, Write},
    path::{Component, Path, PathBuf},
};

pub const RESET_MARKER: &str = "clean-start-1.17.done";
const RESET_COMPLETE: &str = "Forlan Destek clean start 1.17.0\n";

fn marker(local: &Path) -> PathBuf {
    local.join("ForlanDestek-Migrations").join(RESET_MARKER)
}

pub fn reset_complete(local: &Path) -> io::Result<bool> {
    let path = marker(local);
    validate_tree(&path)?;
    match fs::read_to_string(path) {
        Ok(value) => Ok(value == RESET_COMPLETE),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

pub fn preserve_profiles_once(local: &Path) -> io::Result<bool> {
    if reset_complete(local)? {
        return Ok(false);
    }
    let marker = marker(local);
    let parent = marker
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Reset marker has no parent"))?;
    let pending = parent.join("clean-start-1.17.pending");
    validate_tree(parent)?;
    fs::create_dir_all(parent)?;
    validate_tree(&pending)?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&pending)?;
    file.write_all(RESET_COMPLETE.as_bytes())?;
    file.sync_all()?;
    drop(file);
    fs::rename(pending, marker)?;
    Ok(true)
}

pub fn validate_path(path: &Path) -> io::Result<()> {
    if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Cleanup path must be absolute",
        ));
    }
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) => reject_link(&metadata)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

pub fn validate_tree(path: &Path) -> io::Result<()> {
    validate_path(path)?;
    validate_children(path)
}

fn reject_link(metadata: &fs::Metadata) -> io::Result<()> {
    #[cfg(windows)]
    let reparse = {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    };
    #[cfg(not(windows))]
    let reparse = false;
    if metadata.file_type().is_symlink() || reparse {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Cleanup refuses links and junctions",
        ));
    }
    Ok(())
}

fn validate_children(path: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    reject_link(&metadata)?;
    if metadata.is_dir() {
        for entry in fs::read_dir(path)? {
            validate_children(&entry?.path())?;
        }
    }
    Ok(())
}

pub fn remove_owned_tree(base: &Path, name: &str) -> io::Result<()> {
    let mut components = Path::new(name).components();
    if !matches!(components.next(), Some(Component::Normal(_))) || components.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Cleanup name must be one component",
        ));
    }
    let target = base.join(name);
    validate_tree(&target)?;
    match fs::remove_dir_all(&target) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

pub fn owned_tree_paths(logical: &Path, local: &Path, scope: &str) -> io::Result<Vec<PathBuf>> {
    let name = logical
        .file_name()
        .and_then(|v| v.to_str())
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Missing owned directory name")
        })?;
    if !["ForlanDestek", "Forlan Destek"]
        .iter()
        .any(|v| v.eq_ignore_ascii_case(name))
        || !matches!(scope, "Local" | "Roaming")
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Unexpected owned directory",
        ));
    }
    validate_tree(logical)?;
    let local = fs::canonicalize(local)?;
    let mut pending = vec![logical.to_path_buf()];
    let mut roots = Vec::new();
    while let Some(path) = pending.pop() {
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        reject_link(&metadata)?;
        if metadata.is_dir() {
            for entry in fs::read_dir(&path)? {
                pending.push(entry?.path());
            }
        } else if metadata.is_file() {
            let canonical = fs::canonicalize(&path)?;
            let relative = path.strip_prefix(logical).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "File escaped owned tree")
            })?;
            let physical = canonical
                .ancestors()
                .nth(relative.components().count())
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "Physical file escaped owned tree",
                    )
                })?
                .to_path_buf();
            if is_owned_overlay(&physical, &local, scope, name)
                && physical
                    .join(relative)
                    .to_string_lossy()
                    .eq_ignore_ascii_case(&canonical.to_string_lossy())
            {
                validate_tree(&physical)?;
                if !roots.contains(&physical) {
                    roots.push(physical);
                }
            }
        }
    }
    roots.push(logical.to_path_buf());
    Ok(roots)
}

fn is_owned_overlay(physical: &Path, local: &Path, scope: &str, name: &str) -> bool {
    let Ok(relative) = physical.strip_prefix(local) else {
        return false;
    };
    let parts: Vec<_> = relative.components().collect();
    if parts.len() != 5 || parts.iter().any(|p| !matches!(p, Component::Normal(_))) {
        return false;
    }
    let matches = |index: usize, expected: &str| {
        parts[index]
            .as_os_str()
            .to_str()
            .map(|v| v.eq_ignore_ascii_case(expected))
            .unwrap_or(false)
    };
    matches(0, "Packages") && matches(2, "LocalCache") && matches(3, scope) && matches(4, name)
}

pub fn remove_forlan_tree(base: &Path, name: &str, local: &Path, scope: &str) -> io::Result<()> {
    for path in owned_tree_paths(&base.join(name), local, scope)? {
        let parent = path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Owned tree has no parent")
        })?;
        let name = path.file_name().and_then(|v| v.to_str()).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Invalid owned directory name")
        })?;
        remove_owned_tree(parent, name)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_is_limited_to_named_profile_and_rejects_traversal() {
        let base = std::env::temp_dir().join(format!("forlan-reset-test-{}", std::process::id()));
        fs::create_dir_all(base.join("ForlanDestek/config/peers")).unwrap();
        fs::create_dir_all(base.join("RustDesk/config")).unwrap();
        fs::write(base.join("ForlanDestek/config/password.toml"), b"old").unwrap();
        fs::write(base.join("RustDesk/config/keep.toml"), b"keep").unwrap();
        assert!(remove_owned_tree(&base, "../RustDesk").is_err());
        remove_owned_tree(&base, "ForlanDestek").unwrap();
        assert!(!base.join("ForlanDestek").exists());
        assert!(base.join("RustDesk/config/keep.toml").exists());
        assert!(is_owned_overlay(
            &base.join("Packages/test.family/LocalCache/Local/forlandestek"),
            &base,
            "Local",
            "ForlanDestek"
        ));
        assert!(!is_owned_overlay(
            &base.join("Packages/test.family/LocalCache/Local/other-app"),
            &base,
            "Local",
            "ForlanDestek"
        ));
        assert!(!is_owned_overlay(
            &base.join("Packages/test.family/LocalCache/Roaming/forlandestek"),
            &base,
            "Local",
            "ForlanDestek"
        ));
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn update_preserves_profile_without_a_previous_reset_marker() {
        let base = std::env::temp_dir().join(format!("forlan-epoch-test-{}", std::process::id()));
        let roaming = base.join("Roaming");
        let local = base.join("Local");
        let profile = roaming.join("ForlanDestek/config");
        fs::create_dir_all(&profile).unwrap();
        fs::write(profile.join("old.toml"), b"old").unwrap();
        assert!(preserve_profiles_once(&local).unwrap());
        assert_eq!(fs::read(profile.join("old.toml")).unwrap(), b"old");
        assert!(reset_complete(&local).unwrap());
        assert!(!preserve_profiles_once(&local).unwrap());
        fs::remove_dir_all(base).unwrap();
    }
}
