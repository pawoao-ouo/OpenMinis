//
//  ThemeOffloadExtras+Commands.m
//  MinisApp
//
//  ObjC side of the extended `minis-theme` surface: argument parsing and
//  guest→host path resolution for avatars, row icons, per-page wallpapers
//  and single colour overrides. The work itself lives in
//  ThemeOffloadExtras.swift.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "ThemeOffloadExtras.h"
#include "kernel/native_offload.h"

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#else
@interface ThemeOffloadExtras : NSObject
+ (NSDictionary * _Nonnull)setAvatar:(NSString * _Nonnull)role hostPath:(NSString * _Nonnull)path;
+ (NSDictionary * _Nonnull)removeAvatar:(NSString * _Nonnull)role;
+ (NSDictionary * _Nonnull)setIcon:(NSString * _Nonnull)slot hostPath:(NSString * _Nonnull)path;
+ (NSDictionary * _Nonnull)removeIcon:(NSString * _Nonnull)slot;
+ (NSDictionary * _Nonnull)listIconSlots;
+ (NSDictionary * _Nonnull)setWallpaper:(NSString * _Nonnull)scope hostPath:(NSString * _Nonnull)path;
+ (NSDictionary * _Nonnull)removeWallpaper:(NSString * _Nonnull)scope;
+ (NSDictionary * _Nonnull)setColor:(NSString * _Nonnull)role hex:(NSString * _Nonnull)hex
                              scope:(NSString * _Nonnull)scope variant:(NSString * _Nonnull)variant;
+ (NSDictionary * _Nonnull)clearColor:(NSString * _Nonnull)role
                                scope:(NSString * _Nonnull)scope variant:(NSString * _Nonnull)variant;
+ (BOOL)aiAllowsIconSet;
@end
#endif

static NSString *const EXTRA_TOOL_NAME = @"minis-theme";

/// Mirrors ThemeOffload.m's emit_bridge. Kept here so the extended commands
/// do not need to reach back into that file's statics.
int theme_extra_emit(NSDictionary *raw, NSString *action,
                     int stdout_fd, BOOL compact, BOOL quiet) {
    if (![raw isKindOfClass:[NSDictionary class]]) {
        NSDictionary *err = noff_json_error(EXTRA_TOOL_NAME, action, NOFF_ERR_INTERNAL_ERROR,
                                            @"theme bridge returned nothing");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    id okVal = raw[@"ok"];
    BOOL ok = YES;
    if ([okVal isKindOfClass:[NSNumber class]]) ok = [okVal boolValue];
    if (!ok) {
        NSString *code = raw[@"error"] ?: NOFF_ERR_INVALID_ARGS;
        NSString *msg = raw[@"message"] ?: @"theme command failed";
        NSDictionary *err = noff_json_error(EXTRA_TOOL_NAME, action, code, msg);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *payload = [raw mutableCopy];
    [payload removeObjectForKey:@"ok"];
    NSDictionary *result = noff_json_envelope(EXTRA_TOOL_NAME, action, payload);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

/// Resolves `--file`/`--image` to a host path, answering the caller with an
/// error envelope when the path is missing or unmappable.
static NSString *_Nullable extra_host_path(NSString *guest, int stdout_fd,
                                           NSString *action, BOOL compact, BOOL quiet) {
    if (guest.length == 0) {
        NSDictionary *err = noff_json_error(EXTRA_TOOL_NAME, action, NOFF_ERR_INVALID_ARGS,
                                            @"--file <path> is required.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return nil;
    }
    NSString *host = noff_resolve_host_path(guest);
    if (host.length == 0) {
        NSDictionary *err = noff_json_error(
            EXTRA_TOOL_NAME, action, NOFF_ERR_NO_DATA,
            [NSString stringWithFormat:@"Cannot resolve %@", guest]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return nil;
    }
    return host;
}

int theme_extra_avatar(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    // [T-27] --role used to default to `user`, so an AI call that simply
    // forgot the flag overwrote the USER's avatar. Which side is changed
    // must be named, never guessed.
    NSString *role = noff_find_arg(argc, argv, "--role");
    if (role.length == 0) {
        NSDictionary *err = noff_json_error(
            EXTRA_TOOL_NAME, @"avatar", NOFF_ERR_INVALID_ARGS,
            @"--role <user|assistant> is required. `user` is the human's avatar, `assistant` is the AI's own.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    if (![role isEqualToString:@"user"] && ![role isEqualToString:@"assistant"]) {
        NSDictionary *err = noff_json_error(
            EXTRA_TOOL_NAME, @"avatar", NOFF_ERR_INVALID_ARGS,
            @"--role must be `user` or `assistant`.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    BOOL remove = noff_has_flag(argc, argv, "--remove");
    NSDictionary *raw;
    if (remove) {
        raw = [ThemeOffloadExtras removeAvatar:role];
    } else {
        NSString *host = extra_host_path(noff_find_arg(argc, argv, "--file"),
                                         stdout_fd, @"avatar", compact, quiet);
        if (!host) return NOFF_EXIT_INVALID_ARGS;
        raw = [ThemeOffloadExtras setAvatar:role hostPath:host];
    }
    return theme_extra_emit(raw, @"avatar", stdout_fd, compact, quiet);
}

int theme_extra_icon(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    if (noff_has_flag(argc, argv, "--list")) {
        return theme_extra_emit([ThemeOffloadExtras listIconSlots], @"icon",
                                stdout_fd, compact, quiet);
    }
    // [AI theme lock] Icons are not in the AI allowlist (colours,
    // wallpaper, font sizes, avatar). [T-52] The answer itself now lives
    // in Swift (`ThemeOffloadExtras.aiAllowsIconSet`) so the ObjC command
    // surface and any future Swift caller cannot drift apart. Set/clear
    // are gated here with a named-field error, same treatment as
    // `apply`'s locked_field, and nothing is changed. `--list` above
    // stays read-only. Icons are user-only, changed in the settings UI.
    if (![ThemeOffloadExtras aiAllowsIconSet]) {
        NSDictionary *err = noff_json_error(
            EXTRA_TOOL_NAME, @"icon", @"locked_field",
            @"AI theme icon changes are locked. Locked field: icon. "
             "Icons are user-only: change them in the settings UI. "
             "Only `minis-theme icon --list` is available to the AI.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    // [T-52] Unreachable today: icon set/clear is locked for the AI. Kept so
    // the command answers instead of falling off the end if that changes.
    NSDictionary *unsupported = noff_json_error(
        EXTRA_TOOL_NAME, @"icon", @"unsupported_action",
        @"Setting or clearing an icon is not available here. Nothing was changed.");
    noff_emit_json(stdout_fd, unsupported, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

int theme_extra_wallpaper(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *scope = noff_find_arg(argc, argv, "--scope") ?: @"global";
    NSDictionary *raw;
    if (noff_has_flag(argc, argv, "--remove")) {
        raw = [ThemeOffloadExtras removeWallpaper:scope];
    } else {
        NSString *host = extra_host_path(noff_find_arg(argc, argv, "--file"),
                                         stdout_fd, @"wallpaper", compact, quiet);
        if (!host) return NOFF_EXIT_INVALID_ARGS;
        raw = [ThemeOffloadExtras setWallpaper:scope hostPath:host];
    }
    return theme_extra_emit(raw, @"wallpaper", stdout_fd, compact, quiet);
}

int theme_extra_color(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *scope = noff_find_arg(argc, argv, "--scope") ?: @"global";
    // [T-theme-color-read] `--list` 是读，不需要 --role。放在最前面，
    // 否则下面那条 --role 必填会把它挡掉。
    if (noff_has_flag(argc, argv, "--list")) {
        return theme_extra_emit([ThemeOffloadExtras listColors:scope], @"color",
                                stdout_fd, compact, quiet);
    }
    NSString *role = noff_find_arg(argc, argv, "--role");
    if (role.length == 0) {
        NSDictionary *err = noff_json_error(
            EXTRA_TOOL_NAME, @"color", NOFF_ERR_INVALID_ARGS,
            @"--role <role> is required (canvas, surface, accent, …). Use `minis-theme color --list` to see them all with their current values.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    // [T-53] --variant 缺省是 light：AI 漏写就写浅色档，结果里回显但不够显眼。
    // 这里记下是不是缺省，交给结果里显式标注，别让它悄悄发生。
    NSString *variantArg = noff_find_arg(argc, argv, "--variant");
    NSString *variant = variantArg ?: @"light";
    NSDictionary *raw;
    if (noff_has_flag(argc, argv, "--clear")) {
        raw = [ThemeOffloadExtras clearColor:role scope:scope variant:variant];
    } else {
        NSString *hex = noff_find_arg(argc, argv, "--hex");
        if (hex.length == 0) {
            NSDictionary *err = noff_json_error(
                EXTRA_TOOL_NAME, @"color", NOFF_ERR_INVALID_ARGS,
                @"--hex <RRGGBB> is required unless --clear is passed.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        raw = [ThemeOffloadExtras setColor:role hex:hex scope:scope variant:variant];
    }
    // [T-53] 缺省档在结果里显式标出来，别让"我写的是浅色还是它替我选的"
    // 靠猜。给了 --variant 就不加这行。
    // raw[@"ok"] 是个对象指针，@NO 也是非 nil —— 必须取 boolValue，
    // 否则失败的调用也会被加上"缺省浅色档"这句。
    BOOL rawOK = [raw[@"ok"] respondsToSelector:@selector(boolValue)] ? [raw[@"ok"] boolValue] : NO;
    if (rawOK && !variantArg) {
        NSMutableDictionary *annotated = [raw mutableCopy];
        annotated[@"variantDefaulted"] = @YES;
        annotated[@"variantNote"] = @"No --variant was passed, so this wrote the LIGHT palette. Pass --variant dark to change the dark one.";
        raw = annotated;
    }
    return theme_extra_emit(raw, @"color", stdout_fd, compact, quiet);
}
