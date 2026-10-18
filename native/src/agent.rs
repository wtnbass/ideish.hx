//! Agent processes: spawn an ACP agent, queue the lines it prints and write
//! lines to it. A Rust thread reads stdout; Helix's main thread drains the
//! queue from a tick, so no Steel code waits on the pipe.

use std::{
    collections::VecDeque,
    fs::OpenOptions,
    io::{BufRead, BufReader, Write},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
};

use abi_stable::std_types::{RString, RVec};
use steel::{
    rvals::Custom,
    steel_vm::ffi::{FFIModule, FFIValue, IntoFFIVal, RegisterFFIFn},
};

pub fn register(module: &mut FFIModule) {
    module
        .register_fn("agent-spawn", agent_spawn)
        .register_fn("agent-send!", AgentProcess::send)
        .register_fn("agent-drain!", AgentProcess::drain)
        .register_fn("agent-exit-code", AgentProcess::exit_code)
        .register_fn("agent-kill!", AgentProcess::kill)
        .register_fn("path-lookup", path_lookup);
}

#[derive(Default)]
struct Output {
    lines: VecDeque<String>,
    /// Some once stdout closed: the exit code, or -1 when it is unknown
    exit: Option<i32>,
}

pub struct AgentProcess {
    child: Arc<Mutex<Child>>,
    stdin: Mutex<Option<ChildStdin>>,
    output: Arc<Mutex<Output>>,
}

impl Custom for AgentProcess {}

/// args: newline-separated. stderr is appended to log_path.
/// Returns the process, or an error message string.
fn agent_spawn(program: String, args: String, cwd: String, log_path: String) -> FFIValue {
    let log = OpenOptions::new().create(true).append(true).open(&log_path);
    let stderr = match log {
        Ok(file) => Stdio::from(file),
        Err(_) => Stdio::null(),
    };
    let spawned = Command::new(&program)
        .args(args.split('\n').filter(|a| !a.is_empty()))
        .current_dir(&cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(stderr)
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(err) => return FFIValue::StringV(RString::from(format!("{program}: {err}"))),
    };

    let stdout = child.stdout.take();
    let stdin = child.stdin.take();
    let child = Arc::new(Mutex::new(child));
    let output = Arc::new(Mutex::new(Output::default()));

    let sink = Arc::clone(&output);
    let waiter = Arc::clone(&child);
    thread::spawn(move || {
        if let Some(stdout) = stdout {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                sink.lock().unwrap().lines.push_back(line);
            }
        }
        // poll rather than wait, so kill! never blocks on the lock
        let code = loop {
            match waiter.lock().unwrap().try_wait() {
                Ok(Some(status)) => break status.code().unwrap_or(-1),
                Ok(None) => {}
                Err(_) => break -1,
            }
            thread::sleep(std::time::Duration::from_millis(50));
        };
        sink.lock().unwrap().exit = Some(code);
    });

    AgentProcess {
        child,
        stdin: Mutex::new(stdin),
        output,
    }
    .into_ffi_val()
    .unwrap_or(FFIValue::BoolV(false))
}

impl AgentProcess {
    /// Writes one line; #f when the agent's stdin is closed.
    fn send(&self, line: String) -> bool {
        let mut stdin = self.stdin.lock().unwrap();
        let Some(pipe) = stdin.as_mut() else { return false };
        let ok = pipe
            .write_all(line.as_bytes())
            .and_then(|_| pipe.write_all(b"\n"))
            .and_then(|_| pipe.flush())
            .is_ok();
        if !ok {
            *stdin = None;
        }
        ok
    }

    /// The lines printed since the last call, or #f when there are none.
    fn drain(&self) -> FFIValue {
        let mut output = self.output.lock().unwrap();
        if output.lines.is_empty() {
            return FFIValue::BoolV(false);
        }
        FFIValue::Vector(
            output
                .lines
                .drain(..)
                .map(|l| FFIValue::StringV(RString::from(l)))
                .collect::<RVec<_>>(),
        )
    }

    /// #f while the agent runs, its exit code once it has stopped and every
    /// line has been drained.
    fn exit_code(&self) -> FFIValue {
        let output = self.output.lock().unwrap();
        match output.exit {
            Some(code) if output.lines.is_empty() => FFIValue::IntV(code as isize),
            _ => FFIValue::BoolV(false),
        }
    }

    fn kill(&self) {
        *self.stdin.lock().unwrap() = None;
        let _ = self.child.lock().unwrap().kill();
    }
}

/// Full path of a command on PATH, or #f.
fn path_lookup(name: String) -> FFIValue {
    let Some(path) = std::env::var_os("PATH") else {
        return FFIValue::BoolV(false);
    };
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(&name);
        if candidate.is_file() {
            return FFIValue::StringV(RString::from(candidate.to_string_lossy().into_owned()));
        }
    }
    FFIValue::BoolV(false)
}
