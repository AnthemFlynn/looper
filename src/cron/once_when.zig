//! Convert natural-language temporal expressions into absolute UTC epoch
//! seconds, suitable for `looper once <when> <cmd>`.
//!
//! Delegates the parse to vendored Kairoz (vendor/kairoz/), which owns the
//! grammar. This module is a thin shim that:
//!   - Builds a controller-local DateTime reference from `now_epoch_utc`
//!     + `tz_offset_secs` so Kairoz can anchor relative inputs ("in 5 min",
//!     "tomorrow 9am") correctly.
//!   - Maps the variants Kairoz can return onto a single i64 UTC epoch.
//!   - Rejects variants that don't pin a specific minute (date-only,
//!     period, range, clear) — one-shots need minute precision.
//!   - Rejects past or too-near-future times (cron can't fire faster
//!     than the next minute boundary; require at least 30 seconds lead).
//!
//! Returns `null` on any failure mode. Callers emit the user-facing
//! diagnostic; this module is I/O-free.
//!
//! Time-zone convention: `tz_offset_secs` is seconds east of UTC, so
//!   utc_epoch + tz_offset_secs = local_epoch.

const std = @import("std");
const kairoz = @import("kairoz");

/// Minimum seconds between "now" and the target firing time. Cron only
/// resolves to the next minute boundary, so scheduling "in 5 sec" is
/// almost certainly going to miss the upcoming minute and confuse the
/// user. 30s gives a clear "this fires in the NEXT minute" guarantee
/// regardless of where we are in the current minute.
pub const MIN_LEAD_SECS: i64 = 30;

pub const ParseError = error{
    KairozParseFailed,
    UnsupportedVariant,
    TooSoon,
};

/// Convert input to absolute UTC epoch seconds, or fail with one of the
/// classified errors. The error variants let `commands/once.zig` emit
/// targeted diagnostics ("did you mean a date?" vs "the time has passed")
/// without re-parsing.
pub fn parseWhen(input: []const u8, now_epoch_utc: i64, tz_offset_secs: i32) ParseError!i64 {
    const ref_dt = referenceDateTime(now_epoch_utc, tz_offset_secs);
    const parsed = kairoz.parseWithReference(input, ref_dt) catch return error.KairozParseFailed;

    const target_utc: i64 = switch (parsed) {
        .datetime => |dt| naiveToUtc(dt, tz_offset_secs),
        .zoned => |z| z.toInstant().epoch_seconds,
        .instant => |i| i.epoch_seconds,
        .duration => |d| now_epoch_utc + d.seconds,
        // Date-only inputs ("tomorrow", "monday", "2026-12-31", "in 1 day"):
        // Kairoz returns these as `.date` because no time-of-day was given.
        // For one-shot scheduling, we anchor to the REFERENCE TIME-OF-DAY
        // (i.e., "now's clock time") so user intent is preserved:
        //   - "in 1 day" at 3pm  → tomorrow at 3pm
        //   - "tomorrow" at 9am  → tomorrow at 9am
        //   - "2026-12-31" at 5pm → that date at 5pm
        // Predictable, matches natural conversation, and stays consistent
        // with sub-day relative inputs ("in 24 hours" → "now + 24h"). Users
        // who want a specific time can always supply one ("tomorrow at noon").
        .date => |d| naiveToUtc(kairoz.DateTime.init(d, ref_dt.time), tz_offset_secs),
        // Period (next week/month), range (jan to feb), clear — these
        // don't pin a moment. Reject so the caller can ask for one.
        .period, .range, .clear => return error.UnsupportedVariant,
    };

    if (target_utc < now_epoch_utc + MIN_LEAD_SECS) return error.TooSoon;
    return target_utc;
}

/// Build a Kairoz DateTime representing "now in controller-local time".
/// This is the reference Kairoz uses to resolve relative inputs ("tomorrow
/// 9am", "in 5 min") and the today-if-future-else-tomorrow rule for bare
/// time-of-day inputs ("9am").
fn referenceDateTime(now_epoch_utc: i64, tz_offset_secs: i32) kairoz.DateTime {
    const local_epoch: i64 = now_epoch_utc + @as(i64, tz_offset_secs);
    const local_days = @divFloor(local_epoch, 86400);
    const local_sod = local_epoch - local_days * 86400;
    const ref_date = kairoz.Date.epochDaysToDate(@intCast(local_days));
    const ref_time = kairoz.Time.initUnchecked(
        @intCast(@divFloor(local_sod, 3600)),
        @intCast(@mod(@divFloor(local_sod, 60), 60)),
        @intCast(@mod(local_sod, 60)),
        0,
    );
    return kairoz.DateTime.init(ref_date, ref_time);
}

/// Naive DateTime → UTC epoch, treating the DateTime as controller-local.
/// Logic: compute the epoch as if the DateTime were UTC, then subtract
/// the controller's offset to get the true UTC moment.
fn naiveToUtc(dt: kairoz.DateTime, tz_offset_secs: i32) i64 {
    const days: i64 = @intCast(kairoz.Date.dateToEpochDays(dt.date));
    const sod: i64 = @as(i64, dt.time.hour) * 3600 +
        @as(i64, dt.time.minute) * 60 +
        @as(i64, dt.time.second);
    const naive_epoch = days * 86400 + sod;
    return naive_epoch - @as(i64, tz_offset_secs);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 2026-05-24 00:00:00 UTC — a fixed reference point so tests don't depend
/// on the wall clock. Days since epoch: 20597, hence epoch_seconds =
/// 20597 * 86400. Picked to match a recognisable date so test expectations
/// read naturally as offsets from "midnight UTC on 2026-05-24".
const NOW_FIXED: i64 = 1779580800;

test "parseWhen 'in 5 min' returns now + 300" {
    const got = try parseWhen("in 5 min", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 300, got);
}

test "parseWhen 'in 2 hours' returns now + 7200" {
    const got = try parseWhen("in 2 hours", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 7200, got);
}

test "parseWhen 'in 1 day' returns now + 86400 (anchored to ref time)" {
    // Kairoz returns `.date` for day+ relative inputs; our shim anchors
    // to the reference time-of-day, which is midnight here (NOW_FIXED).
    // So target = tomorrow midnight = NOW_FIXED + 86400.
    const got = try parseWhen("in 1 day", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 86400, got);
}

test "parseWhen 'in 1 day' anchored to mid-day reference picks up that time" {
    // Reference at 15:00 UTC → "in 1 day" = same date+1 at 15:00.
    const now_3pm = NOW_FIXED + 15 * 3600;
    const got = try parseWhen("in 1 day", now_3pm, 0);
    try testing.expectEqual(now_3pm + 86400, got);
}

test "parseWhen absolute ISO datetime in UTC" {
    // 2026-05-25T15:00:00Z = NOW_FIXED + 24h + 15h.
    const got = try parseWhen("2026-05-25T15:00:00Z", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 24 * 3600 + 15 * 3600, got);
}

test "parseWhen 'tomorrow 9am' in UTC" {
    // NOW_FIXED is 2026-05-24 00:00 UTC, so "tomorrow" = 2026-05-25
    // and "9am" of that day = NOW_FIXED + 24h + 9h.
    const got = try parseWhen("tomorrow 9am", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 24 * 3600 + 9 * 3600, got);
}

test "parseWhen 'tomorrow 9am' in PDT (-07:00)" {
    // NOW_FIXED is 2026-05-24 00:00 UTC, which is 2026-05-23 17:00 PDT.
    // So from PDT's perspective, "tomorrow" = 2026-05-24 (NOT 2026-05-25).
    // "9am" of 2026-05-24 PDT = 09:00 PDT = 16:00 UTC = NOW_FIXED + 16h.
    const got = try parseWhen("tomorrow 9am", NOW_FIXED, -25200);
    try testing.expectEqual(NOW_FIXED + 16 * 3600, got);
}

test "parseWhen accepts bare 'tomorrow', anchoring to reference time-of-day" {
    // With NOW_FIXED at midnight, "tomorrow" → tomorrow's midnight =
    // NOW_FIXED + 86400. The "anchor to reference time" rule keeps
    // natural-language scheduling working without forcing a time-of-day
    // on every input.
    const got = try parseWhen("tomorrow", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 86400, got);
}

test "parseWhen rejects period words like 'next week'" {
    // .period variant doesn't pin a moment — surface to the caller.
    const got = parseWhen("next week", NOW_FIXED, 0);
    try testing.expectError(error.UnsupportedVariant, got);
}

test "parseWhen rejects garbage input" {
    const got = parseWhen("this is not a time", NOW_FIXED, 0);
    try testing.expectError(error.KairozParseFailed, got);
}

test "parseWhen rejects times in the past" {
    // 2020-01-01 (way before NOW_FIXED in 2026) → TooSoon.
    const got = parseWhen("2020-01-01T12:00:00Z", NOW_FIXED, 0);
    try testing.expectError(error.TooSoon, got);
}

test "parseWhen rejects times under the 30s lead floor" {
    // "in 10 sec" → close enough that we'd miss the next-minute boundary.
    const got = parseWhen("in 10 sec", NOW_FIXED, 0);
    try testing.expectError(error.TooSoon, got);
}

test "parseWhen accepts exactly MIN_LEAD_SECS into the future" {
    // Boundary test: a 30s lead is allowed.
    const got = try parseWhen("in 30 sec", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 30, got);
}

test "parseWhen handles bare time-of-day (today-if-future-else-tomorrow)" {
    // NOW_FIXED is midnight UTC. "9am" → today 09:00 → epoch + 9h.
    const got = try parseWhen("9am", NOW_FIXED, 0);
    try testing.expectEqual(NOW_FIXED + 9 * 3600, got);
}
