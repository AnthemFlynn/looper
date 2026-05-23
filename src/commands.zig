//! Subcommand surface. Each verb lives in its own focused module under
//! `commands/`; this file is the public façade `main.zig` imports.
//!
//!   core      applyMutation funnel + nextFor (TZ-aware next-run dispatch)
//!   mutate    add / edit / rm / enable / disable
//!   view      ls / show / run / explain
//!   backup    backup / backups / backups prune / restore / import
//!   doctor    preflight against the resolved target set
//!   preflight `--check-command` reachability probe (shared by add + doctor)
//!
//! The historical single file lived at >1700 lines and violated the
//! project's own 800-line ceiling (CLAUDE.md). Splitting by cohesion
//! keeps `main.zig`'s import surface stable: every public function
//! that used to live here is re-exported below.

const std = @import("std");

const core = @import("commands/core.zig");
const mutate = @import("commands/mutate.zig");
const view = @import("commands/view.zig");
const backup_cmd = @import("commands/backup.zig");
const doctor = @import("commands/doctor.zig");
const preflight = @import("commands/preflight.zig");
const runs = @import("commands/runs.zig");
const exec = @import("commands/exec.zig");

// core
pub const applyMutation = core.applyMutation;
pub const nextFor = core.nextFor;

// mutate
pub const cmdAdd = mutate.cmdAdd;
pub const cmdToggle = mutate.cmdToggle;
pub const cmdEdit = mutate.cmdEdit;
pub const cmdRm = mutate.cmdRm;

// view
pub const cmdLs = view.cmdLs;
pub const cmdShow = view.cmdShow;
pub const cmdRun = view.cmdRun;
pub const cmdExplain = view.cmdExplain;

// backup
pub const cmdBackup = backup_cmd.cmdBackup;
pub const cmdRestore = backup_cmd.cmdRestore;
pub const cmdBackups = backup_cmd.cmdBackups;
pub const cmdBackupsPrune = backup_cmd.cmdBackupsPrune;
pub const cmdImport = backup_cmd.cmdImport;

// doctor
pub const cmdDoctor = doctor.cmdDoctor;
pub const dirWritable = doctor.dirWritable;
pub const fileReadable = doctor.fileReadable;

// preflight
pub const ReachResult = preflight.ReachResult;
pub const extractBinary = preflight.extractBinary;
pub const commandReachable = preflight.commandReachable;
pub const hasInPath = preflight.hasInPath;

// runs
pub const cmdRunsLs = runs.cmdRunsLs;
pub const cmdRunsShow = runs.cmdRunsShow;
pub const cmdRunsPrune = runs.cmdRunsPrune;
pub const RunsFilter = runs.Filter;
pub const parseRunsStatusFilter = runs.parseStatusFilter;

// exec
pub const cmdExec = exec.cmdExec;

// Ensure the test harness compiles every submodule. `main.zig`'s
// test {} block imports this file, so anything referenced here gets
// pulled into the test binary.
test {
    _ = core;
    _ = mutate;
    _ = view;
    _ = backup_cmd;
    _ = doctor;
    _ = preflight;
    _ = runs;
    _ = exec;
}
