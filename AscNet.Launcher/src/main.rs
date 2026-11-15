#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod animation;
mod steam;
#[cfg(windows)]
mod ui;

use anyhow::{Context, Result};
use ascnet_launcher::{distribution, install, local, package};
use serde_json::json;
use std::{
    env,
    path::{Path, PathBuf},
};

fn main() {
    #[cfg(windows)]
    {
        let args: Vec<String> = env::args().skip(1).collect();
        if args.first().is_some_and(|arg| arg == "--patch-worker") {
            std::process::exit(install::patch_worker(&args));
        }
    }
    if let Err(error) = run() {
        #[cfg(windows)]
        if env::args_os().len() == 1 {
            ui::show_fatal(&format!("{error:#}"));
        }
        eprintln!("{}", local::logged_error(&format!("{error:#}")));
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    if let Some(launcher) = distribution::active_launcher(&executable_dir()?)? {
        let arguments: Vec<_> = env::args_os().skip(1).collect();
        let mut command = std::process::Command::new(&launcher);
        command.current_dir(launcher.parent().context("active launcher has no parent directory")?);
        if arguments.is_empty() {
            command.spawn().context("start the active PGR 4.9 launcher")?;
        } else {
            let status = command.args(arguments).status().context("run the active PGR 4.9 launcher")?;
            std::process::exit(status.code().unwrap_or(1));
        }
        return Ok(());
    }
    if !distribution::PAIRED && ascnet_launcher::updater::startup()? {
        return Ok(());
    }
    let args: Vec<String> = env::args().skip(1)
        .filter(|arg| arg != "--self-update-health" && arg != "--self-update-rolled-back").collect();
    if args.as_slice() != ["--verify-release"] {
        local::launcher_log("Launcher started")?;
    }
    if args.is_empty() {
        #[cfg(windows)]
        {
            return ui::run();
        }
        #[cfg(not(windows))]
        anyhow::bail!("the graphical launcher is available on Windows only");
    }
    match args[0].as_str() {
        "--setup" => {
            require_len(&args, 2, "--setup <game-directory>")?;
            let game = PathBuf::from(&args[1]);
            if !steam::valid_game_directory(&game) { anyhow::bail!("game directory does not contain PGR.exe") }
            if install::game_running()? { anyhow::bail!("close PGR.exe before setup") }
            #[cfg(windows)]
            let build = ui::setup_from_cli(&game, &mut |line| eprintln!("{line}"))?;
            #[cfg(not(windows))]
            let build = distribution::Distribution::load(&executable_dir()?)?
                .prepare(&game, &mut |line| eprintln!("{line}"))?;
            println!("{}", build.revision);
        }
        "--inspect" => {
            require_len(&args, 2, "--inspect <game-directory>")?;
            let package = built_package()?;
            let state = install::inspect(Path::new(&args[1]), &package)?;
            println!("{}", serde_json::to_string_pretty(&state_json(state))?);
        }
        "--install" => {
            require_len(&args, 2, "--install <game-directory>")?;
            let package = built_package()?;
            let backup = install::install_with_consent(Path::new(&args[1]), &package, &mut |line| eprintln!("{line}"))?;
            println!("{}", backup.display());
        }
        "--restore" => {
            require_len(&args, 2, "--restore <game-directory>")?;
            install::restore_with_consent(Path::new(&args[1]), &mut |line| eprintln!("{line}"))?;
        }
        "--check-server" => {
            require_len(&args, 2, "--check-server <origin>")?;
            let origin = package::validate_server_origin(&args[1])?;
            let response = ascnet_launcher::download::wine_safe(reqwest::blocking::Client::builder().no_proxy()).build()?
                .get(format!("{origin}/api/launcher/status")).send()?.error_for_status()?;
            let value: serde_json::Value = response.json()?;
            println!("{}", serde_json::to_string_pretty(&value)?);
        }
        "--verify-release" => {
            require_len(&args, 1, "--verify-release")?;
            let distribution = distribution::Distribution::load(&executable_dir()?)?;
            anyhow::ensure!(distribution.release.is_some(), "This is not a paired launcher release");
        }
        _ => anyhow::bail!("usage: ascnet-launcher [--setup GAME | --inspect GAME | --install GAME | --restore GAME | --check-server ORIGIN | --verify-release]"),
    }
    Ok(())
}

fn built_package() -> Result<package::PatchPackage> {
    let distribution = distribution::Distribution::load(&executable_dir()?)?;
    let build = distribution.load_build()?.context("no local build; run --setup first")?;
    package::load_package(&build.patch_directory)
}

fn executable_dir() -> Result<PathBuf> {
    Ok(env::current_exe()
        .context("locating launcher executable")?
        .parent()
        .context("launcher executable has no parent directory")?
        .to_path_buf())
}

fn require_len(args: &[String], len: usize, usage: &str) -> Result<()> {
    if args.len() != len {
        anyhow::bail!("usage: ascnet-launcher {usage}")
    }
    Ok(())
}

fn state_json(state: install::PatchState) -> serde_json::Value {
    match state {
        install::PatchState::Unpatched => json!({"state":"unpatched"}),
        install::PatchState::Current => json!({"state":"current"}),
        install::PatchState::UpdateAvailable => json!({"state":"updateAvailable"}),
        install::PatchState::AdoptionRequired => json!({"state":"adoptionRequired"}),
        install::PatchState::Unsupported(reason) => json!({"state":"unsupported","reason":reason}),
        install::PatchState::RepairRequired(reason) => {
            json!({"state":"repairRequired","reason":reason})
        }
    }
}
