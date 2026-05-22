//! ANSI color escape codes. Use via `ctx.k(CODE)` so `--no-color`
//! / `NO_COLOR` flip them to empty strings.
pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const CYAN = "\x1b[36m";
