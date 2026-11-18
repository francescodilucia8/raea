//! The verbs that run raea's local tools: sound (`raea sao`, `tokensynth`, `setup-audio`, `sounds`: foley and an
//! instrument's notes made by local models, and the open sample libraries), `raea splat` (footage trained into a
//! Gaussian splat), `raea song` (a song's energy map, apps/tools/src/song.rs) and `raea gen` (generation flows on
//! made.app, fal, Replicate, OpenRouter, Modal and ComfyUI, with sao as the local model: apps/tools/src/generate.rs).

pub mod generate;
/// `raea motion` and `raea setup motion`: body motion made by Kimodo, on MLX on a Mac, on PyTorch elsewhere (apps/motion)
#[cfg(not(all(target_os = "macos", target_arch = "x86_64")))]
pub use raea_app_motion as motion;

#[cfg(all(target_os = "macos", target_arch = "x86_64"))]
pub mod motion {
    pub const USAGE: &str = "raea motion";
    pub const SETUP_USAGE: &str = "raea setup motion";
    pub const ABOUT: &str = "unavailable on Intel macOS (Kimodo requires Apple Silicon MLX on Mac)";
    pub const SETUP_ABOUT: &str = ABOUT;

    pub fn motion(_: &[String]) -> Result<String, String> {
        Err(ABOUT.into())
    }

    pub fn setup(args: &[String]) -> Result<String, String> {
        motion(args)
    }
}
pub mod song;
pub mod sound;
pub mod splat;

/// the MCP servers `raea skills install` offers an agent (blender, for a running Blender)
pub mod agent_mcp;
pub mod agent_hooks;
/// Grok Bot as a `raea skills install` target: its copy staged on this Mac, and the links that finish it in Grok Bot
pub mod agent_grokbot;
/// where each agent reads a person's skills
pub mod agent_skills;
/// `raea setup blender` and `raea blender run`
pub mod blender;
