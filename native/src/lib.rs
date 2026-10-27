//! Native side of ideish.hx.
//!
//! Filesystem events, `git status`, agent processes and terminals all run on
//! Rust threads and are queued here. Helix's main thread drains the queue from a tick, so no Steel code runs
//! off the main thread (see mattwparas/helix#138).

use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    process::Command,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use abi_stable::std_types::{RString, RVec};
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use notify::{EventKind, RecommendedWatcher, RecursiveMode};
use notify_debouncer_full::{new_debouncer_opt, DebounceEventResult, Debouncer, NoCache};
use steel::{
    rvals::Custom,
    steel_vm::ffi::{FFIModule, FFIValue, IntoFFIVal, RegisterFFIFn},
};

mod agent;
mod terminal;

steel::declare_module!(build_module);

pub fn build_module() -> FFIModule {
    let mut module = FFIModule::new("ideish/native");
    module
        .register_fn("watcher-new", watcher_new)
        .register_fn("watcher-set-dirs!", Watcher::set_dirs)
        .register_fn("watcher-set-files!", Watcher::set_files)
        .register_fn("watcher-drain!", Watcher::drain)
        .register_fn("watcher-git-status!", Watcher::git_status)
        .register_fn("watcher-git?", Watcher::has_git);
    agent::register(&mut module);
    terminal::register(&mut module);
    module
}

const DEBOUNCE: Duration = Duration::from_millis(100);

struct GitRepo {
    toplevel: PathBuf,
    git_dir: PathBuf,
}

#[derive(Default)]
struct GitJob {
    running: bool,
    rerun: bool,
    result: Option<FFIValue>,
}

struct State {
    root: PathBuf,
    /// The workspace root as Steel spells it; paths sent back use this prefix
    root_given: String,
    repo: Option<GitRepo>,
    ignore: Gitignore,
    /// Directories the tree shows expanded: canonical path -> path as Steel knows it
    dirs: HashMap<PathBuf, String>,
    /// Files open in Helix: canonical path -> path as Steel knows it
    files: HashMap<PathBuf, String>,
    changed_dirs: HashSet<String>,
    changed_files: HashSet<String>,
    git_dirty: bool,
    git: GitJob,
    /// Set once the setup thread has found the repository and started watching
    ready: bool,
}

pub struct Watcher {
    state: Arc<Mutex<State>>,
    /// Filled by the setup thread; dropping it stops the watch
    _debouncer: Arc<Mutex<Option<Debouncer<RecommendedWatcher, NoCache>>>>,
}

impl Custom for Watcher {}

fn canonical(path: &str) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path))
}

fn find_repo(root: &Path) -> Option<GitRepo> {
    let output = Command::new("git")
        .args(["rev-parse", "--show-toplevel", "--absolute-git-dir"])
        .current_dir(root)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut lines = text.lines();
    let toplevel = PathBuf::from(lines.next()?);
    let git_dir = canonical(lines.next()?);
    Some(GitRepo { toplevel, git_dir })
}

fn build_ignore(root: &Path, repo: Option<&GitRepo>) -> Gitignore {
    let base = repo.map(|r| r.toplevel.as_path()).unwrap_or(root);
    let mut builder = GitignoreBuilder::new(canonical(&base.to_string_lossy()));
    builder.add(base.join(".gitignore"));
    if let Some(repo) = repo {
        builder.add(repo.git_dir.join("info").join("exclude"));
    }
    if base != root {
        builder.add(root.join(".gitignore"));
    }
    builder.build().unwrap_or_else(|_| Gitignore::empty())
}

impl State {
    fn record(&mut self, path: &Path) {
        if let Some(repo) = &self.repo {
            if let Ok(rel) = path.strip_prefix(&repo.git_dir) {
                let name = rel.to_string_lossy();
                if !name.ends_with(".lock")
                    && (name == "HEAD"
                        || name == "index"
                        || name == "packed-refs"
                        || name.starts_with("refs"))
                {
                    self.git_dirty = true;
                }
                return;
            }
        }
        if !path.starts_with(&self.root)
            || path.components().any(|c| c.as_os_str() == ".git")
        {
            return;
        }
        if self.repo.is_some()
            && !self
                .ignore
                .matched_path_or_any_parents(path, path.is_dir())
                .is_ignore()
        {
            self.git_dirty = true;
        }
        if let Some(dir) = path.parent().and_then(|p| self.dirs.get(p)) {
            self.changed_dirs.insert(dir.clone());
        }
        if let Some(dir) = self.dirs.get(path) {
            self.changed_dirs.insert(dir.clone());
        }
        if let Some(file) = self.files.get(path) {
            self.changed_files.insert(file.clone());
        }
    }
}

/// Returns at once; finding the repository and starting the watch run on a
/// thread so a large workspace does not hold up Helix's startup.
fn watcher_new(root: String) -> FFIValue {
    let root_path = canonical(&root);
    let state = Arc::new(Mutex::new(State {
        root: root_path.clone(),
        root_given: root.trim_end_matches('/').to_string(),
        repo: None,
        ignore: Gitignore::empty(),
        dirs: HashMap::new(),
        files: HashMap::new(),
        changed_dirs: HashSet::new(),
        changed_files: HashSet::new(),
        git_dirty: false,
        git: GitJob::default(),
        ready: false,
    }));
    let slot = Arc::new(Mutex::new(None));

    let shared = Arc::clone(&state);
    let debouncer_slot = Arc::clone(&slot);
    thread::spawn(move || {
        let repo = find_repo(&root_path);
        let ignore = build_ignore(&root_path, repo.as_ref());
        let outside_git_dir = repo
            .as_ref()
            .map(|r| r.git_dir.clone())
            .filter(|dir| !dir.starts_with(&root_path));
        {
            let mut state = shared.lock().unwrap();
            state.repo = repo;
            state.ignore = ignore;
        }

        let sink = Arc::clone(&shared);
        // NoCache: the recommended cache on macOS walks the whole tree to
        // track renames, which ideish does not need
        let debouncer = new_debouncer_opt::<_, RecommendedWatcher, NoCache>(
            DEBOUNCE,
            None,
            move |result: DebounceEventResult| {
                let Ok(events) = result else { return };
                let mut state = sink.lock().unwrap();
                for event in events.iter() {
                    if matches!(event.kind, EventKind::Access(_)) {
                        continue;
                    }
                    for path in &event.paths {
                        state.record(path);
                    }
                }
            },
            NoCache::new(),
            notify::Config::default(),
        );
        if let Ok(mut debouncer) = debouncer {
            if debouncer.watch(&root_path, RecursiveMode::Recursive).is_ok() {
                // a workspace below the repository root does not see the git dir otherwise
                if let Some(git_dir) = outside_git_dir {
                    let _ = debouncer.watch(&git_dir, RecursiveMode::NonRecursive);
                    let _ = debouncer.watch(&git_dir.join("refs"), RecursiveMode::Recursive);
                }
                *debouncer_slot.lock().unwrap() = Some(debouncer);
            }
        }

        let requested = {
            let mut state = shared.lock().unwrap();
            state.ready = true;
            std::mem::replace(&mut state.git.rerun, false)
        };
        if requested {
            start_git_status(&shared);
        }
    });

    Watcher {
        state,
        _debouncer: slot,
    }
    .into_ffi_val()
    .unwrap_or(FFIValue::BoolV(false))
}

/// Runs `git status` on a Rust thread. A request while one is running, or
/// before the setup thread is done, is folded into a single later run.
fn start_git_status(shared: &Arc<Mutex<State>>) {
    let mut state = shared.lock().unwrap();
    if !state.ready || state.git.running {
        state.git.rerun = true;
        return;
    }
    let Some(toplevel) = state.repo.as_ref().map(|r| r.toplevel.clone()) else {
        return;
    };
    let root = state.root.clone();
    let root_given = state.root_given.clone();
    state.git.running = true;
    let shared = Arc::clone(shared);
    thread::spawn(move || loop {
        let result = run_git_status(&toplevel, &root, &root_given);
        let mut state = shared.lock().unwrap();
        state.git.result = Some(result);
        if state.git.rerun {
            state.git.rerun = false;
            continue;
        }
        state.git.running = false;
        break;
    });
}

fn path_map(joined: &str) -> HashMap<PathBuf, String> {
    joined
        .split('\n')
        .filter(|p| !p.is_empty())
        .map(|p| (canonical(p), p.to_string()))
        .collect()
}

fn strings(values: impl IntoIterator<Item = String>) -> FFIValue {
    FFIValue::Vector(
        values
            .into_iter()
            .map(|s| FFIValue::StringV(RString::from(s)))
            .collect(),
    )
}

impl Watcher {
    /// Newline-separated paths of the directories whose listing is on screen.
    fn set_dirs(&self, joined: String) {
        self.state.lock().unwrap().dirs = path_map(&joined);
    }

    /// Newline-separated paths of the files open in Helix.
    fn set_files(&self, joined: String) {
        self.state.lock().unwrap().files = path_map(&joined);
    }

    fn has_git(&self) -> bool {
        self.state.lock().unwrap().repo.is_some()
    }

    /// `#f` when nothing happened, otherwise
    /// `#(git-dirty? #(dir ...) #(file ...) git-result-or-#f)`.
    fn drain(&self) -> FFIValue {
        let mut state = self.state.lock().unwrap();
        let git_result = state.git.result.take();
        if !state.git_dirty
            && state.changed_dirs.is_empty()
            && state.changed_files.is_empty()
            && git_result.is_none()
        {
            return FFIValue::BoolV(false);
        }
        let dirs = std::mem::take(&mut state.changed_dirs);
        let files = std::mem::take(&mut state.changed_files);
        let git_dirty = std::mem::replace(&mut state.git_dirty, false);
        FFIValue::Vector(RVec::from(vec![
            FFIValue::BoolV(git_dirty),
            strings(dirs),
            strings(files),
            git_result.unwrap_or(FFIValue::BoolV(false)),
        ]))
    }

    fn git_status(&self) {
        start_git_status(&self.state);
    }
}

fn priority(status: &str) -> u8 {
    match status {
        "conflict" => 6,
        "deleted" => 5,
        "modified" => 4,
        "renamed" => 3,
        "added" => 2,
        "untracked" => 1,
        _ => 0,
    }
}

fn status_of(xy: &str) -> &'static str {
    let has = |c: char| xy.contains(c);
    if has('D') {
        "deleted"
    } else if has('M') || has('T') {
        "modified"
    } else if has('R') || has('C') {
        "renamed"
    } else if has('A') {
        "added"
    } else {
        "modified"
    }
}

/// `#(branch ahead behind #(path status path status ...) head #(dir ...))`,
/// where head is the commit HEAD points at (`(initial)` before the first) and
/// the dirs are the untracked directories git listed without their contents.
/// Paths are absolute, spelled from `root_given`, and limited to the workspace.
/// Directories carry the most important status found below them.
fn run_git_status(toplevel: &Path, root: &Path, root_given: &str) -> FFIValue {
    let output = Command::new("git")
        .args([
            "--no-optional-locks",
            "status",
            "--porcelain=v2",
            "--branch",
            "-z",
            "--ignored=matching",
        ])
        .current_dir(toplevel)
        .output();
    let Ok(output) = output else {
        return FFIValue::BoolV(false);
    };
    if !output.status.success() {
        return FFIValue::BoolV(false);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut fields = text.split('\0');

    let mut branch = String::new();
    let mut head = String::new();
    let (mut ahead, mut behind) = (0isize, 0isize);
    let mut statuses: HashMap<PathBuf, &'static str> = HashMap::new();
    let mut untracked_dirs: Vec<PathBuf> = Vec::new();
    let mut put = |path: &str, status: &'static str, propagate: bool| {
        let abs = toplevel.join(path.trim_end_matches('/'));
        let mut entry = Some(abs.as_path());
        while let Some(p) = entry {
            let keep = statuses.get(p).map_or(true, |old| priority(old) < priority(status));
            if keep {
                statuses.insert(p.to_path_buf(), status);
            }
            if !propagate || p == toplevel {
                break;
            }
            entry = p.parent().filter(|parent| parent.starts_with(toplevel));
            if entry == Some(toplevel) {
                break;
            }
        }
    };

    while let Some(field) = fields.next() {
        if let Some(oid) = field.strip_prefix("# branch.oid ") {
            head = oid.to_string();
        } else if let Some(name) = field.strip_prefix("# branch.head ") {
            branch = name.to_string();
        } else if let Some(ab) = field.strip_prefix("# branch.ab ") {
            let mut parts = ab.split(' ');
            ahead = parts.next().and_then(|a| a.trim_start_matches('+').parse().ok()).unwrap_or(0);
            behind = parts.next().and_then(|b| b.trim_start_matches('-').parse().ok()).unwrap_or(0);
        } else if field.starts_with("1 ") {
            if let Some(path) = field.splitn(9, ' ').nth(8) {
                put(path, status_of(&field[2..4]), true);
            }
        } else if field.starts_with("2 ") {
            if let Some(path) = field.splitn(10, ' ').nth(9) {
                put(path, status_of(&field[2..4]), true);
            }
            fields.next(); // the original path of the rename
        } else if field.starts_with("u ") {
            if let Some(path) = field.splitn(11, ' ').nth(10) {
                put(path, "conflict", true);
            }
        } else if let Some(path) = field.strip_prefix("? ") {
            if path.ends_with('/') {
                untracked_dirs.push(toplevel.join(path.trim_end_matches('/')));
            }
            put(path, "untracked", true);
        } else if let Some(path) = field.strip_prefix("! ") {
            put(path, "ignored", false);
        }
    }

    let given = |path: &Path| {
        let rel = path.strip_prefix(root).ok().filter(|rel| !rel.as_os_str().is_empty())?;
        Some(FFIValue::StringV(RString::from(format!("{}/{}", root_given, rel.to_string_lossy()))))
    };
    let mut entries = RVec::new();
    for (path, status) in statuses {
        let Some(given) = given(&path) else { continue };
        entries.push(given);
        entries.push(FFIValue::StringV(RString::from(status)));
    }
    let untracked_dirs: RVec<FFIValue> = untracked_dirs.iter().filter_map(|p| given(p)).collect();
    FFIValue::Vector(RVec::from(vec![
        FFIValue::StringV(RString::from(branch)),
        FFIValue::IntV(ahead),
        FFIValue::IntV(behind),
        FFIValue::Vector(entries),
        FFIValue::StringV(RString::from(head)),
        FFIValue::Vector(untracked_dirs),
    ]))
}
