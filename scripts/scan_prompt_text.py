#!/usr/bin/env python3
"""Heuristically inventory static model-facing text in the iOS source tree.

Run from the repository root:
    python3 scripts/scan_prompt_text.py

This is a candidate finder, not a Swift compiler or semantic classifier. The
scope is intentionally registered below; runtime/user-authored values are not
available to a source-only scan. See docs/prompt-text-inventory.md for the
confirmed input map, exclusions, and known limits.
"""

from __future__ import annotations

import argparse
import codecs
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

EXPECTED_BASELINE_COMMIT = "641a2b546239fdd244a36d6324b8c6c1c7cfc873"
# Counts from the prior recorded scan. It predates later source registrations
# and nested-string interpolation parsing; deltas below are historical
# comparisons, not source-scope-only changes.
PREVIOUSLY_RECORDED_COUNTS = {
    "registered_paths": 52,
    "selected_static_literals": 2983,
    "selected_static_markdown_documents": 1,
    "directive_candidate_sentences": 397,
    "subject_candidate_sentences": 75,
}
BASELINE_EXPECTED_COUNTS = {
    "registered_paths": 62,
    "selected_static_literals": 3457,
    "selected_static_markdown_documents": 1,
    "directive_candidate_sentences": 413,
    "subject_candidate_sentences": 89,
}
CANDIDATE_CEILINGS = {
    "directive_candidate_sentences": 413,
    "subject_candidate_sentences": 89,
}
SOURCE_DISCOVERY_ROOT = "src/ios"
# Add newly introduced non-prompt files here only after reviewing them. Stale
# entries are errors, so this list cannot silently become a permanent catch-all.
NEW_SOURCE_EXCLUSIONS: set[str] = set()
# Exact (path, candidate sentence) pairs reviewed as non-model-facing changes.
CHANGED_CANDIDATE_EXCLUSIONS: set[tuple[str, str]] = set()
MARKDOWN_DOCUMENT_SOURCES = ("src/ios/Resources/user-manual.md",)

# These selectors are source-code anchors, not claims that every runtime branch
# is active. Function/property bodies are located lexically so line drift does
# not silently change the scan window. `property` also supports stored literal
# declarations (e.g. static let identityTemplate = "...").
SYMBOL_SCOPES: dict[str, dict[str, list[str]]] = {
    "src/ios/Agent/Chat/AIChatViewModel.swift": {
        "function": [
            "buildTurnSystemPrompt", "ambientContextFragment", "queuedTimingNote",
            "appendQueuedPromptsAsOwnTurns",
        ],
        "property": ["userProfilePromptSection", "baseSystemPrompt", "memoryStatusFragment"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+Attachments.swift": {
        "function": ["processAttachments"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+BackgroundTask.swift": {
        "function": ["waitIfBrowserTakeover"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+SuspensionResume.swift": {
        "function": ["continueAfterRestoredAsk"],
    },
    "src/ios/Agent/Chat/AmbientContext.swift": {
        "function": [
            "fragment", "timeFactsLine", "gapLine", "listeningLine", "deviceLine",
            "clock", "timeOfDayWord",
        ],
        "property": ["defaultUsageRule"],
        "switch": ["path.status"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift": {
        "function": [
            "makeAgentTools", "defaultCatalogItems", "renderCatalogFragment",
            "appleCompactSection", "subAgentRosterSection",
        ],
    },
    "src/ios/Agent/Chat/ChatStore.swift": {
        "function": ["toAgentMessage"],
        "property": ["queuedFollowUpBridgeText"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+ManualTools.swift": {
        "function": ["executeSetEnvVar", "executeSetEnvVarSync", "executeSwitchPersona", "executeSetTTSDefaultGroup"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+Offloading.swift": {
        "function": ["imagePlaceholderText"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift": {
        "function": ["elidedImagePlaceholder"],
    },
    "src/ios/Agent/BrowserUse/BrowserUseManager.swift": {
        "function": ["timedOutNavigationResult"],
    },
    "src/ios/Agent/Session/SoulStore.swift": {
        "function": ["identitySection", "userProfileSection"],
        "property": ["identityTemplate"],
    },
    "src/ios/Agent/Session/PersonaStore.swift": {
        "property": ["stewardSoulContent"],
    },
    "src/ios/Agent/Session/SkillStore.swift": {"function": ["skillPromptFragment"]},
    "src/ios/Agent/Session/MCPStore.swift": {"function": ["systemPromptSnippet"]},
    "src/ios/Shared/UserManualMirror.swift": {"function": ["indexFragment"]},
    "src/ios/Providers/LLMTypes.swift": {
        "property": ["capabilityPromptFragment", "agentBehaviorPromptFragment"],
    },
    "src/ios/Providers/Voice/TTSPaper.swift": {
        "function": ["standingCapability", "paperIfRelevant"],
    },
    "src/ios/Views/Chat/AIChatView.swift": {
        "function": [
            "promptCatalogSummary", "promptDrawerContent", "systemPromptFragment",
            "recognizeSticker",
        ],
    },
    "src/ios/Agent/Evolution/EvolutionInjector.swift": {"function": ["turnFragment"]},
    "src/ios/Agent/Chat/AIChatViewModel+Persistence.swift": {
        "function": ["historyWithEmptyToolResultReminder", "personaReminderText"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift": {
        "function": [
            "emptyResultNote", "delegationPrompt", "executeDelegateTask",
            "cancelSubAgentTask", "subAgentStatus", "steerSubAgentTask",
            "resumeSubAgentTask",
        ],
        "property": ["subAgentIdentitySection", "subAgentSteerNudgePrompt", "subAgentResumeNotice"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+TitleGeneration.swift": {
        "function": ["suggestFolder", "callSubModelForTitle"],
    },
    "src/ios/Agent/Chat/AIChatViewModel+BlockSummary.swift": {"function": ["summarizeTurnBlocks"]},
    "src/ios/Agent/Chat/AIChatViewModel+Compaction.swift": {
        "function": ["generateCompactSummary", "compactSummaryWrappedText"],
    },
    "src/ios/Agent/Jobs/ScheduledJobRunner.swift": {
        "function": ["buildPulsePrompt", "scheduledEnvelope"],
    },
    "src/ios/Providers/ProviderConfigStore.swift": {"function": ["pingModel"]},
    "src/ios/Providers/Voice/CorrectionStrategy.swift": {
        "function": ["buildPrompt"],
        "property": ["systemPrompt"],
    },
    "src/ios/Providers/Voice/VoiceProvider.swift": {
        "function": ["transcribeChatBased"],
    },
    "src/ios/Providers/VisionGroupResolver.swift": {
        "function": ["describe", "describeOnce", "failureText", "attachmentPlaceholder"],
        "property": ["describePrompt", "systemPrompt"],
    },
    "src/ios/Providers/Anthropic/AnthropicAgentProvider.swift": {
        "function": ["convertMessages"],
    },
    # Claude Code OAuth's prompt is generated from private build customization;
    # anchor its source property without scanning unrelated resolver diagnostics.
    "src/ios/Providers/Anthropic/AnthropicProvider.swift": {
        "property": ["claudeCodeSystemPrompt"],
    },
    "src/ios/Providers/Antigravity/AntigravityAgentProvider.swift": {
        "function": ["convertMessages"],
    },
    "src/ios/Providers/Gemini/GeminiAgentProvider.swift": {
        "function": ["convertMessages"],
    },
    "src/ios/Providers/OpenAI/OpenAIAgentProvider.swift": {
        "function": ["convertMessagesChatCompletions", "convertMessagesResponsesAPI"],
    },
    "src/ios/Shared/ImagePayloadPrep.swift": {
        "function": [
            "gatedForVisionCapability", "gatedToolImage", "replacingImagesWithPlaceholders",
        ],
        "property": ["reason"],
    },
    "src/ios/Providers/ImageOCRTier.swift": {
        "function": ["textForImage", "frameOCR"],
    },
    "src/ios/Views/Chat/TurnDetailSheet.swift": {"function": ["startAITranslation"]},
    "src/ios/NativeOffloads/ModelUseOffloadBridge.swift": {"function": ["runJudgePrompt"]},
    "src/ios/Providers/OpenAI/OpenAIProvider.swift": {
        "function": ["generateImage", "generateImageViaCodexResponses"],
    },
    "src/ios/Views/Providers/ModelQuickTestSheet.swift": {"function": ["performTest"]},
    "src/ios/Agent/Bridge/MCPManagementTools.swift": {
        "function": ["dialogDefinitions", "handleDialogCall", "addMCP", "listMCP", "removeMCP", "toggleMCP"],
    },
    "src/ios/BridgeCore/Sources/BridgeCore/Kernel/BridgeMetaTools.swift": {
        "function": ["makeServer", "handleSearch", "handleCommand"],
    },
    "src/ios/BridgeCore/Sources/BridgeCore/Kernel/ToolPapers.swift": {
        "function": ["paperBlock"],
        "property": [
            "reportIssue", "sensitiveApproval", "bluetooth", "clipboard",
            "location", "notification", "photos", "photosDelete",
        ],
    },
}

# These files contain actual model-input reminder/feedback producers as well as
# tag-handling code. Only literals containing the registered marker are
# collected; parser/UI-only strings are intentionally not included.
REMINDER_MARKER_SCOPES = {
    "src/ios/Agent/Chat/AIChatViewModel.swift": "<system-reminder>",
    "src/ios/Agent/Chat/AIChatViewModel+Persistence.swift": "<system-reminder>",
    "src/ios/Agent/Chat/AIChatViewModel+Attachments.swift": "<system-reminder>",
    "src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift": "<system-reminder>",
    "src/ios/Agent/Chat/AIChatViewModel+CodeBlockEditing.swift": "<system-reminder>",
    "src/ios/Agent/Chat/AIChatViewModel+AskUser.swift": "<system-reminder>",
    "src/ios/Agent/Shell/BashismReminder.swift": "<system-reminder>",
    "src/ios/Shared/EnvVarRedactor.swift": "<system-reminder>",
    "src/ios/Views/Chat/MessageActionBar.swift": "<system_runtime_feedback",
}

# Tool-result functions are selected by executable sink markers after comments
# and string bodies have been masked. Dynamic output payloads remain out of the
# static scan, but static result/error/reminder literals in these functions are
# candidates. Use a return-specific error marker so logger.error(...) calls are
# not mistaken for model-visible results. Function scopes can still include
# nearby non-model strings for human review.
TOOL_SINK_MARKERS = (
    "FileToolResult(", "ToolOutput(", "ToolExecOutcome(", ".toolResult(",
    "errorResult(", "textResult(", "CallTool.Result(", "BrowserActionResult(",
    "return .error(",
)
TOOL_RESULT_ROOTS = (
    "src/ios/Agent/Chat",
    "src/ios/Agent/Bridge",
    "src/ios/Agent/BrowserUse",
    "src/ios/BridgeCore/Sources/BridgeCore/Kernel",
)
TOOL_RESULT_FILE_RE = re.compile(
    r"(?:\+.*Tools|MCPManagementTools|MCPAggregator|BridgeMetaTools|"
    r"(?:Bluetooth|Clipboard|Location|Notification|Photos)DeviceTool|"
    r"BrowserUseActions|BrowserUseManager|BrowserTabPool|ReportIssueTool|WebSearchBridgeTool)\.swift$"
)

KEYWORD_RE = re.compile(
    r"\b(?:must|always|never|do\s+not|don't|only|important|should|please|help|assist)\b"
    r"|必须|总是|永远|绝不|不许|只能|仅限|禁止|务必|请|不要|帮助|协助|应当|应该",
    re.IGNORECASE,
)
IMPERATIVE_START_RE = re.compile(
    r"^\s*(?:[-*#>\"'“‘（(\[]\s*)*"
    r"(use|read|write|call|return|respond|reply|avoid|keep|make|check|run|send|ask|tell|"
    r"include|follow|treat|continue|stop|choose|prefer)\b"
    r"|^\s*(?:[-*#>\"'“‘（(\[]\s*)*(请|不要|别|务必|必须|先|只需|直接|记得)",
    re.IGNORECASE,
)
SUBJECT_RE = re.compile(
    r"^\s*(?:[-*#>\"'“‘（(\[]\s*)*(?:you\b|your\b|the assistant\b|assistant\b|"
    r"the model\b|model\b|the agent\b|agent\b|the user request\b|user request\b|"
    r"the user\b|user\b|你|您|助手|助理|模型|智能体|用户请求|用户)",
    re.IGNORECASE,
)

SENTENCE_RE = re.compile(r"[^.!?。！？;；\n]+(?:[.!?。！？;；]+|$)")


@dataclass(frozen=True)
class StringLiteral:
    start: int
    end: int
    start_line: int
    text: str
    line_map: tuple[int, ...]


@dataclass(frozen=True)
class ScopeRange:
    start: int
    end: int
    label: str


@dataclass(frozen=True)
class Candidate:
    path: str
    line: int
    text: str
    cues: tuple[str, ...]
    scan_range: str = "unregistered"
    literal_start: int = -1


@dataclass
class FileResult:
    literals: int = 0
    markdown_documents: int = 0
    directive_candidates: list[Candidate] | None = None
    subject_candidates: list[Candidate] | None = None

    def __post_init__(self) -> None:
        self.directive_candidates = []
        self.subject_candidates = []


def mask_non_code(source: str) -> tuple[str, list[StringLiteral]]:
    """Blank comments and string literals while retaining offsets/newlines."""
    chars = list(source)
    literals: list[StringLiteral] = []
    i = 0
    line = 1
    n = len(source)

    def blank(a: int, b: int) -> None:
        for p in range(a, b):
            if chars[p] not in "\r\n":
                chars[p] = " "

    while i < n:
        if source.startswith("//", i):
            j = i + 2
            while j < n and source[j] not in "\r\n":
                j += 1
            blank(i, j)
            i = j
            continue
        if source.startswith("/*", i):
            start = i
            j = _skip_block_comment(source, start)
            if j is None:
                raise SwiftScanError(f"unterminated Swift block comment at line {line}")
            blank(start, j)
            line += source.count("\n", start, j)
            i = j
            continue

        opener = _string_opener(source, i)
        if opener is not None:
            nested_literals: list[StringLiteral] = []
            end, text, line_map = _read_string(
                source, i, line, opener, nested_literals
            )
            literals.append(StringLiteral(i, end, line, text, tuple(line_map)))
            literals.extend(nested_literals)
            blank(i, end)
            line += source.count("\n", i, end)
            i = end
            continue

        if source[i] == "\n":
            line += 1
        i += 1

    return "".join(chars), literals


def _string_opener(source: str, i: int) -> tuple[int, int, bool] | None:
    """Return (quote_start, quote_width, raw) for a Swift string opener."""
    n = len(source)
    if source[i] == '"':
        width = 3 if source.startswith('"""', i) else 1
        return i, width, False
    if source[i] != "#":
        return None
    j = i
    while j < n and source[j] == "#":
        j += 1
    if j >= n or source[j] != '"':
        return None
    width = 3 if source.startswith('"""', j) else 1
    return j, width, True


class SwiftScanError(ValueError):
    """A Swift lexical boundary could not be resolved safely."""


def _skip_block_comment(source: str, start: int) -> int | None:
    depth = 1
    i = start + 2
    while i < len(source) and depth:
        if source.startswith("/*", i):
            depth += 1
            i += 2
        elif source.startswith("*/", i):
            depth -= 1
            i += 2
        else:
            i += 1
    return i if depth == 0 else None


def _find_interpolation_close(source: str, opening_paren: int) -> int | None:
    """Find a Swift interpolation's closing paren, skipping nested literals/comments."""
    depth = 1
    i = opening_paren + 1
    while i < len(source):
        if source.startswith("//", i):
            newline = source.find("\n", i + 2)
            i = len(source) if newline < 0 else newline + 1
            continue
        if source.startswith("/*", i):
            end = _skip_block_comment(source, i)
            if end is None:
                return None
            i = end
            continue
        opener = _string_opener(source, i)
        if opener is not None:
            end = _skip_swift_string(source, i, opener)
            if end is None:
                return None
            i = end
            continue
        if source[i] == "(":
            depth += 1
        elif source[i] == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def _skip_swift_string(
    source: str, start: int, opener: tuple[int, int, bool]
) -> int | None:
    quote_start, quote_width, raw = opener
    hash_count = quote_start - start
    close = '"' * quote_width + ("#" * hash_count if raw else "")
    interpolation = "\\" + ("#" * hash_count) + "("
    i = quote_start + quote_width
    while i < len(source):
        if source.startswith(close, i):
            return i + len(close)
        if source.startswith(interpolation, i):
            closing_paren = _find_interpolation_close(source, i + len(interpolation) - 1)
            if closing_paren is None:
                return None
            i = closing_paren + 1
            continue
        if source[i] == "\\" and not raw and i + 1 < len(source):
            i += 2
            continue
        i += 1
    return None


def _read_string(
    source: str,
    start: int,
    start_line: int,
    opener: tuple[int, int, bool],
    nested_literals: list[StringLiteral],
) -> tuple[int, str, list[int]]:
    quote_start, quote_width, raw = opener
    hash_count = quote_start - start
    close = '"' * quote_width + ("#" * hash_count if raw else "")
    i = quote_start + quote_width
    out: list[str] = []
    line_map: list[int] = []
    line = start_line + source.count("\n", start, i)

    def append(value: str, source_line: int) -> None:
        out.extend(value)
        line_map.extend([source_line] * len(value))

    while i < len(source):
        if source.startswith(close, i):
            return i + len(close), "".join(out), line_map

        # Keep the interpolation as dynamic in the enclosing string, but also
        # inventory static Swift string literals inside its expression. Dynamic
        # values and non-string code remain masked and are never expanded.
        interp = "\\" + ("#" * hash_count) + "("
        if source.startswith(interp, i):
            expr_start = i
            expression_start = i + len(interp)
            closing_paren = _find_interpolation_close(source, i + len(interp) - 1)
            if closing_paren is None:
                raise SwiftScanError(
                    f"unresolved Swift interpolation boundary at line {line}"
                )
            expression = source[expression_start:closing_paren]
            _, expression_literals = mask_non_code(expression)
            line_offset = source.count("\n", 0, expression_start)
            nested_literals.extend(
                StringLiteral(
                    expression_start + literal.start,
                    expression_start + literal.end,
                    line_offset + literal.start_line,
                    literal.text,
                    tuple(line_offset + source_line for source_line in literal.line_map),
                )
                for literal in expression_literals
            )
            i = closing_paren + 1
            append("⟪dynamic⟫", line)
            line += source.count("\n", expr_start, i)
            continue

        if source[i] == "\\" and not raw and i + 1 < len(source):
            esc = source[i + 1]
            decoded = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", "\\": "\\", '"': '"'}
            if esc in decoded:
                append(decoded[esc], line)
                i += 2
                continue
            # Swift Unicode scalar escape: \u{hex}.
            if esc == "u" and i + 2 < len(source) and source[i + 2] == "{":
                end = source.find("}", i + 3)
                if end != -1:
                    try:
                        append(chr(int(source[i + 3 : end], 16)), line)
                    except (ValueError, OverflowError):
                        append("�", line)
                    i = end + 1
                    continue
            # Line continuation in a Swift string removes the newline and
            # indentation. Preserve a space to avoid joining two words.
            if esc == "\n":
                i += 2
                while i < len(source) and source[i] in " \t":
                    i += 1
                append(" ", line)
                line += 1
                continue
            append(esc, line)
            i += 2
            continue

        ch = source[i]
        append(ch, line)
        if ch == "\n":
            line += 1
        i += 1

    raise SwiftScanError(f"unterminated Swift string at line {start_line}")


def _matching_brace(masked: str, opening: int) -> int | None:
    depth = 0
    for i in range(opening, len(masked)):
        if masked[i] == "{":
            depth += 1
        elif masked[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return None


def _line_start(source: str, pos: int) -> int:
    return source.rfind("\n", 0, pos) + 1


def _line_end(source: str, pos: int) -> int:
    idx = source.find("\n", pos)
    return len(source) if idx < 0 else idx


def find_symbol_ranges(source: str, masked: str, kind: str, name: str) -> list[ScopeRange]:
    ranges: list[ScopeRange] = []
    if kind == "function":
        pattern = re.compile(r"\bfunc\s+" + re.escape(name) + r"\b")
        for match in pattern.finditer(masked):
            opening = masked.find("{", match.end())
            if opening < 0:
                continue
            # Guard against an unrelated later brace if the signature wraps
            # into another declaration; normal Swift signatures are short.
            next_decl = re.search(r"\bfunc\s+\w+\b", masked[match.end() : opening])
            if next_decl:
                continue
            end = _matching_brace(masked, opening)
            if end is not None:
                ranges.append(ScopeRange(match.start(), end, f"func {name}"))
        return ranges

    if kind == "switch":
        pattern = re.compile(r"\bswitch\s+" + re.escape(name) + r"\b")
        for match in pattern.finditer(masked):
            opening = masked.find("{", match.end())
            if opening < 0:
                continue
            end = _matching_brace(masked, opening)
            if end is not None:
                ranges.append(ScopeRange(match.start(), end, f"switch {name}"))
        return ranges

    pattern = re.compile(r"\b(?:let|var)\s+" + re.escape(name) + r"\b")
    for match in pattern.finditer(masked):
        start = match.start()
        line_start = _line_start(source, start)
        declaration_indent = len(source[line_start:start]) - len(source[line_start:start].lstrip(" \t"))
        line_end = _line_end(masked, match.end())
        segment = masked[match.end() : line_end]
        # Computed property: its opening brace is on the declaration line.
        opening = segment.find("{")
        assignment = segment.find("=")
        if opening >= 0 and (assignment < 0 or opening < assignment):
            brace = match.end() + opening
            end = _matching_brace(masked, brace)
            if end is not None:
                ranges.append(ScopeRange(start, end, f"property {name}"))
            continue

        # Stored string property: capture its initializer through the next
        # sibling declaration/closing brace at the same indentation.
        end = len(source)
        for offset in range(line_end + 1, len(source)):
            if offset != 0 and source[offset - 1] != "\n":
                continue
            eol = _line_end(source, offset)
            raw_line = source[offset:eol]
            stripped = raw_line.lstrip(" \t")
            if not stripped or stripped.startswith("//"):
                continue
            indent = len(raw_line) - len(stripped)
            code_line = masked[offset:eol]
            if stripped.startswith("}") and indent <= declaration_indent:
                end = offset
                break
            if indent <= declaration_indent and re.match(
                r"(?:(?:private|public|internal|static|nonisolated|override|class|final|lazy|weak|let|var)\s+)*(?:func|var|let)\s+\w+",
                code_line.lstrip(),
            ):
                end = offset
                break
        ranges.append(ScopeRange(start, end, f"property {name}"))
    return ranges


def find_function_ranges(source: str, masked: str) -> Iterable[ScopeRange]:
    for match in re.finditer(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\b", masked):
        opening = masked.find("{", match.end())
        if opening < 0:
            continue
        next_decl = re.search(r"\bfunc\s+\w+\b", masked[match.end() : opening])
        if next_decl:
            continue
        end = _matching_brace(masked, opening)
        if end is not None:
            yield ScopeRange(match.start(), end, f"func {match.group(1)}")


def split_sentences(literal: StringLiteral) -> Iterable[tuple[str, int, int]]:
    for match in SENTENCE_RE.finditer(literal.text):
        sentence = match.group(0).strip()
        if not sentence:
            continue
        left_trim = len(match.group(0)) - len(match.group(0).lstrip())
        char_index = match.start() + left_trim
        line = literal.line_map[char_index] if char_index < len(literal.line_map) else literal.start_line
        yield sentence, line, char_index


def cue_names(sentence: str, regex: re.Pattern[str]) -> tuple[str, ...]:
    found: list[str] = []
    for match in regex.finditer(sentence):
        cue = match.group(0).strip()
        normalized = cue.lower()
        if normalized not in found:
            found.append(normalized)
    return tuple(found)


def candidates_in_file(
    path: str,
    source: str,
    scan_ranges: dict[int, str] | None = None,
) -> list[Candidate]:
    if path.endswith(".swift"):
        _, literals = mask_non_code(source)
    else:
        line_map: list[int] = []
        line = 1
        for char in source:
            line_map.append(line)
            if char == "\n":
                line += 1
        literals = [StringLiteral(0, len(source), 1, source, tuple(line_map))]

    candidates: list[Candidate] = []
    for literal in literals:
        scan_range = (scan_ranges or {}).get(literal.start, "unregistered")
        for sentence, line, _ in split_sentences(literal):
            keyword_cues = cue_names(sentence, KEYWORD_RE)
            imperative_cues = cue_names(sentence, IMPERATIVE_START_RE)
            directive_cues = tuple(
                [f"keyword:{cue}" for cue in keyword_cues]
                + [f"imperative-start:{cue}" for cue in imperative_cues]
            )
            subject_cues = cue_names(sentence, SUBJECT_RE)
            if directive_cues:
                candidates.append(
                    Candidate(path, line, sentence, directive_cues, scan_range, literal.start)
                )
            if subject_cues:
                candidates.append(
                    Candidate(path, line, sentence, subject_cues, scan_range, literal.start)
                )
    return candidates


def git_head(root: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=root, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def summarize(file_results: dict[str, FileResult]) -> dict[str, int]:
    return {
        "registered_paths": sum(
            bool(result.literals or result.markdown_documents) for result in file_results.values()
        ),
        "selected_static_literals": sum(result.literals for result in file_results.values()),
        "selected_static_markdown_documents": sum(
            result.markdown_documents for result in file_results.values()
        ),
        "directive_candidate_sentences": sum(
            len(result.directive_candidates or []) for result in file_results.values()
        ),
        "subject_candidate_sentences": sum(
            len(result.subject_candidates or []) for result in file_results.values()
        ),
    }


def candidate_occurrence_delta(
    current: Iterable[Candidate], baseline: Iterable[Candidate]
) -> Counter[tuple[str, str, str]]:
    """Count added candidates by path, registered scan range, and sentence."""
    current_counts = Counter((item.path, item.scan_range, item.text) for item in current)
    baseline_counts = Counter((item.path, item.scan_range, item.text) for item in baseline)
    return current_counts - baseline_counts


def read_text_or_issue(path: Path, rel_path: str, issues: list[str]) -> str | None:
    """Read UTF-8 source without turning an unreadable file into a traceback."""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        issues.append(
            f"cannot read UTF-8 source {rel_path}: {type(error).__name__}"
        )
        return None


def selected_literal_scopes(
    root: Path,
    rel_path: str,
    source: str,
    unresolved: list[str] | None = None,
) -> dict[int, str]:
    """Map selected literal starts to the first registered lexical scan range."""
    selected: dict[int, str] = {}
    masked, literals = mask_non_code(source)

    for kind, names in SYMBOL_SCOPES.get(rel_path, {}).items():
        for name in names:
            ranges = find_symbol_ranges(source, masked, kind, name)
            if not ranges and unresolved is not None:
                unresolved.append(f"missing {kind} selector: {rel_path}::{name}")
            for scope in ranges:
                for literal in literals:
                    if scope.start <= literal.start < scope.end:
                        selected.setdefault(literal.start, f"{kind}:{name}")

    marker = REMINDER_MARKER_SCOPES.get(rel_path)
    if marker is not None:
        for literal in literals:
            if marker in literal.text:
                selected.setdefault(literal.start, f"reminder:{marker}")

    in_tool_result_root = any(
        rel_path.startswith(f"{root_rel}/") for root_rel in TOOL_RESULT_ROOTS
    )
    if in_tool_result_root and TOOL_RESULT_FILE_RE.search(Path(rel_path).name):
        for scope in find_function_ranges(source, masked):
            body = masked[scope.start : scope.end]
            if not any(marker in body for marker in TOOL_SINK_MARKERS):
                continue
            for literal in literals:
                if scope.start <= literal.start < scope.end:
                    selected.setdefault(literal.start, f"tool-result:{scope.label}")

    return selected


def is_utf8_text_file(path: Path) -> bool:
    """Identify text resources by content so uncommon prompt-file extensions are covered."""
    decoder = codecs.getincrementaldecoder("utf-8")()
    has_nul = False
    try:
        with path.open("rb") as source:
            while chunk := source.read(8192):
                has_nul = has_nul or b"\0" in chunk
                decoder.decode(chunk, final=False)
        decoder.decode(b"", final=True)
    except UnicodeDecodeError:
        return False
    except OSError:
        return True  # Fail closed: an unreadable new file still needs review.
    return not has_nul


def new_source_registration_issues(
    root: Path, file_results: dict[str, FileResult]
) -> list[str]:
    """Require disposition for every UTF-8 text file added under src/ios since batch 0."""
    try:
        baseline_listing = subprocess.check_output(
            [
                "git", "ls-tree", "-r", "--name-only", EXPECTED_BASELINE_COMMIT,
                "--", SOURCE_DISCOVERY_ROOT,
            ],
            cwd=root,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return [f"cannot compare {SOURCE_DISCOVERY_ROOT} with baseline {EXPECTED_BASELINE_COMMIT}"]

    baseline_paths = set(baseline_listing.splitlines())
    source_root = root / SOURCE_DISCOVERY_ROOT
    current_paths = {
        path.relative_to(root).as_posix()
        for path in source_root.rglob("*")
        if path.is_file() and is_utf8_text_file(path)
    }
    new_paths = current_paths - baseline_paths
    explicit_registrations = (
        set(SYMBOL_SCOPES) | set(REMINDER_MARKER_SCOPES) | set(MARKDOWN_DOCUMENT_SOURCES)
    )
    automatically_scanned = {
        path for path, result in file_results.items()
        if result.literals or result.markdown_documents
    }
    issues: list[str] = []

    for path in sorted(NEW_SOURCE_EXCLUSIONS - new_paths):
        issues.append(f"stale non-prompt source exclusion (remove it): {path}")
    for path in sorted(new_paths):
        registered_or_scanned = path in explicit_registrations or path in automatically_scanned
        excluded = path in NEW_SOURCE_EXCLUSIONS
        if registered_or_scanned and excluded:
            issues.append(f"source is both scanned and excluded (remove exclusion): {path}")
        elif not registered_or_scanned and not excluded:
            issues.append(
                f"new iOS source is not registered or explicitly excluded: {path}"
            )
    return issues


def changed_candidate_issues(
    root: Path, file_results: dict[str, FileResult]
) -> list[str]:
    """Flag new heuristic candidate wording outside currently scanned prompt scopes."""
    try:
        baseline_listing = subprocess.check_output(
            ["git", "ls-tree", "-r", "--name-only", EXPECTED_BASELINE_COMMIT, "--", SOURCE_DISCOVERY_ROOT],
            cwd=root,
            text=True,
            stderr=subprocess.DEVNULL,
        )
        changed_listing = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", EXPECTED_BASELINE_COMMIT, "--", SOURCE_DISCOVERY_ROOT],
            cwd=root,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return [f"cannot compare changed string candidates with baseline {EXPECTED_BASELINE_COMMIT}"]

    baseline_paths = set(baseline_listing.splitlines())
    source_root = root / SOURCE_DISCOVERY_ROOT
    current_text_paths = {
        path.relative_to(root).as_posix()
        for path in source_root.rglob("*")
        if path.is_file() and is_utf8_text_file(path)
    }
    new_paths = current_text_paths - baseline_paths
    changed_paths = set(changed_listing.splitlines()) | new_paths
    issues: list[str] = []
    new_candidates: Counter[tuple[str, str]] = Counter()

    for rel_path in sorted(changed_paths & current_text_paths):
        current_text = read_text_or_issue(root / rel_path, rel_path, issues)
        if current_text is None:
            continue
        try:
            current_ranges = selected_literal_scopes(root, rel_path, current_text, issues)
            current_candidates = candidates_in_file(rel_path, current_text, current_ranges)
        except SwiftScanError as error:
            issues.append(f"cannot safely scan changed source {rel_path}: {error}")
            continue
        if rel_path not in baseline_paths:
            baseline_candidates: list[Candidate] = []
        else:
            try:
                baseline_bytes = subprocess.check_output(
                    ["git", "show", f"{EXPECTED_BASELINE_COMMIT}:{rel_path}"],
                    cwd=root,
                    stderr=subprocess.DEVNULL,
                )
                baseline_text = baseline_bytes.decode("utf-8")
            except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as error:
                issues.append(
                    f"cannot read baseline source {rel_path}: {type(error).__name__}"
                )
                continue
            try:
                baseline_ranges = selected_literal_scopes(root, rel_path, baseline_text, issues)
                baseline_candidates = candidates_in_file(rel_path, baseline_text, baseline_ranges)
            except SwiftScanError as error:
                issues.append(f"cannot safely scan baseline source {rel_path}: {error}")
                continue

        delta = candidate_occurrence_delta(current_candidates, baseline_candidates)
        for (path, scan_range, sentence), count in delta.items():
            if scan_range == "unregistered":
                new_candidates[(path, sentence)] += count

    for identity in sorted(CHANGED_CANDIDATE_EXCLUSIONS - set(new_candidates)):
        issues.append(
            f"stale changed-candidate exclusion (remove it): {identity[0]} "
            "(candidate wording omitted)"
        )
    for path, sentence in sorted(new_candidates):
        identity = (path, sentence)
        excluded = identity in CHANGED_CANDIDATE_EXCLUSIONS
        if not excluded:
            occurrences = new_candidates[identity]
            issues.append(
                f"new candidate string outside registered scan ranges ({occurrences} occurrence(s)): "
                f"{path} (candidate wording omitted)"
            )
    return issues


def baseline_gate_failures(
    root: Path,
    head: str,
    metrics: dict[str, int],
    exact_baseline: bool,
) -> list[str]:
    failures: list[str] = []
    if exact_baseline:
        if head != EXPECTED_BASELINE_COMMIT:
            failures.append(
                f"exact batch-0 replay requires HEAD {EXPECTED_BASELINE_COMMIT}, got {head}"
            )
        for name, expected in BASELINE_EXPECTED_COUNTS.items():
            actual = metrics[name]
            if actual != expected:
                failures.append(f"{name}: expected exactly {expected}, got {actual}")
        try:
            changed_sources = subprocess.check_output(
                ["git", "status", "--porcelain", "--untracked-files=all", "--", SOURCE_DISCOVERY_ROOT],
                cwd=root,
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            failures.append(f"cannot verify that {SOURCE_DISCOVERY_ROOT} matches HEAD")
        else:
            if changed_sources:
                failures.append(f"exact batch-0 replay requires a clean {SOURCE_DISCOVERY_ROOT} tree")
        return failures

    for name, ceiling in CANDIDATE_CEILINGS.items():
        actual = metrics[name]
        if actual > ceiling:
            failures.append(f"{name}: ceiling is {ceiling}, got {actual}")
    return failures


def collect(root: Path) -> tuple[dict[str, FileResult], list[str], str]:
    file_results: dict[str, FileResult] = defaultdict(FileResult)
    unresolved: list[str] = []
    seen_literals: set[tuple[str, int]] = set()

    def analyze(
        path: str,
        literals: list[StringLiteral],
        selected: set[int] | None = None,
        count_as_markdown_document: bool = False,
        scan_ranges: dict[int, str] | None = None,
    ) -> None:
        result = file_results[path]
        for literal in literals:
            if selected is not None and literal.start not in selected:
                continue
            key = (path, literal.start)
            if key in seen_literals:
                continue
            seen_literals.add(key)
            if count_as_markdown_document:
                result.markdown_documents += 1
            else:
                result.literals += 1
            scan_range = (scan_ranges or {}).get(literal.start, "unregistered")
            for sentence, line, _ in split_sentences(literal):
                keyword_cues = cue_names(sentence, KEYWORD_RE)
                imperative_cues = cue_names(sentence, IMPERATIVE_START_RE)
                directive_cues = tuple(
                    [f"keyword:{cue}" for cue in keyword_cues]
                    + [f"imperative-start:{cue}" for cue in imperative_cues]
                )
                subject_cues = cue_names(sentence, SUBJECT_RE)
                if directive_cues:
                    result.directive_candidates.append(
                        Candidate(path, line, sentence, directive_cues, scan_range, literal.start)
                    )
                if subject_cues:
                    result.subject_candidates.append(
                        Candidate(path, line, sentence, subject_cues, scan_range, literal.start)
                    )

    for rel_path, _kinds in SYMBOL_SCOPES.items():
        path = root / rel_path
        if not path.is_file():
            unresolved.append(f"missing file: {rel_path}")
            continue
        source = read_text_or_issue(path, rel_path, unresolved)
        if source is None:
            continue
        try:
            _, literals = mask_non_code(source)
            scan_ranges = selected_literal_scopes(root, rel_path, source, unresolved)
        except SwiftScanError as error:
            unresolved.append(f"cannot safely scan Swift source {rel_path}: {error}")
            continue
        analyze(rel_path, literals, set(scan_ranges), scan_ranges=scan_ranges)

    # Markdown is a model-visible source in its own right, not a Swift string
    # literal. Scan each registered document as one text unit while preserving
    # source line numbers for review.
    for rel_path in MARKDOWN_DOCUMENT_SOURCES:
        path = root / rel_path
        if not path.is_file():
            unresolved.append(f"missing Markdown source: {rel_path}")
            continue
        text = read_text_or_issue(path, rel_path, unresolved)
        if text is None:
            continue
        line_map: list[int] = []
        line = 1
        for char in text:
            line_map.append(line)
            if char == "\n":
                line += 1
        document = StringLiteral(0, len(text), 1, text, tuple(line_map))
        analyze(
            rel_path,
            [document],
            count_as_markdown_document=True,
            scan_ranges={0: "markdown:full-document"},
        )

    for rel_path, marker in REMINDER_MARKER_SCOPES.items():
        path = root / rel_path
        if not path.is_file():
            unresolved.append(f"missing reminder source: {rel_path}")
            continue
        source = read_text_or_issue(path, rel_path, unresolved)
        if source is None:
            continue
        try:
            _, literals = mask_non_code(source)
        except SwiftScanError as error:
            unresolved.append(f"cannot safely scan Swift source {rel_path}: {error}")
            continue
        selected = {literal.start for literal in literals if marker in literal.text}
        analyze(
            rel_path,
            literals,
            selected,
            scan_ranges={offset: f"reminder:{marker}" for offset in selected},
        )

    # Scan executable functions that construct tool results. This excludes
    # comments and string literals before testing sink markers, then includes
    # all literals in those result-producing functions for human review.
    for root_rel in TOOL_RESULT_ROOTS:
        directory = root / root_rel
        if not directory.is_dir():
            unresolved.append(f"missing tool-result directory: {root_rel}")
            continue
        for path in sorted(directory.rglob("*.swift")):
            rel_path = path.relative_to(root).as_posix()
            if not TOOL_RESULT_FILE_RE.search(path.name):
                continue
            source = read_text_or_issue(path, rel_path, unresolved)
            if source is None:
                continue
            try:
                _, literals = mask_non_code(source)
                scan_ranges = selected_literal_scopes(root, rel_path, source, unresolved)
            except SwiftScanError as error:
                unresolved.append(f"cannot safely scan Swift source {rel_path}: {error}")
                continue
            selected_offsets = set(scan_ranges)
            if selected_offsets:
                analyze(rel_path, literals, selected_offsets, scan_ranges=scan_ranges)

    return dict(file_results), unresolved, git_head(root)


def render_text(
    file_results: dict[str, FileResult],
    unresolved: list[str],
    head: str,
    metrics: dict[str, int],
    check_mode: str,
    check_failures: list[str],
    include_candidate_text: bool = False,
) -> str:
    directive_total = sum(len(r.directive_candidates or []) for r in file_results.values())
    subject_total = sum(len(r.subject_candidates or []) for r in file_results.values())
    literal_total = sum(r.literals for r in file_results.values())
    markdown_total = sum(r.markdown_documents for r in file_results.values())
    gate_details = (
        f"Candidate ceilings: directive <= {CANDIDATE_CEILINGS['directive_candidate_sentences']}; "
        f"role-subject <= {CANDIDATE_CEILINGS['subject_candidate_sentences']}"
        if check_mode == "candidate-ceilings"
        else (
            "Exact registered-scope batch-0 counts: "
            f"paths={BASELINE_EXPECTED_COUNTS['registered_paths']}; "
            f"Swift literals={BASELINE_EXPECTED_COUNTS['selected_static_literals']}; "
            f"Markdown documents={BASELINE_EXPECTED_COUNTS['selected_static_markdown_documents']}; "
            f"directive={BASELINE_EXPECTED_COUNTS['directive_candidate_sentences']}; "
            f"role-subject={BASELINE_EXPECTED_COUNTS['subject_candidate_sentences']}"
        )
    )
    lines = [
        "Model-visible prompt-text scan (static lexical candidates; not semantic findings)",
        "WARNING: candidate wording is omitted by default; --include-candidate-text exposes original source text, which may be sensitive and must be reviewed before sharing.",
        f"HEAD: {head}",
        f"Expected baseline commit: {EXPECTED_BASELINE_COMMIT} ({'match' if head == EXPECTED_BASELINE_COMMIT else 'different'})",
        f"Baseline check mode: {check_mode}",
        f"Baseline gate: {'FAIL' if check_failures or unresolved else 'PASS'}",
        gate_details,
        f"Registered paths with selected text: {metrics['registered_paths']}",
        f"Selected static Swift string literals: {literal_total}",
        f"Selected static Markdown documents: {markdown_total}",
        f"Directive-keyword / imperative-start candidate sentences: {directive_total}",
        f"Explicit agent/model/user subject candidate sentences: {subject_total}",
        "Comparison with the earlier recorded scan (source and parser coverage both changed): "
        f"{PREVIOUSLY_RECORDED_COUNTS['registered_paths']}/"
        f"{PREVIOUSLY_RECORDED_COUNTS['selected_static_literals']}/"
        f"{PREVIOUSLY_RECORDED_COUNTS['selected_static_markdown_documents']}/"
        f"{PREVIOUSLY_RECORDED_COUNTS['directive_candidate_sentences']}/"
        f"{PREVIOUSLY_RECORDED_COUNTS['subject_candidate_sentences']} -> "
        f"{BASELINE_EXPECTED_COUNTS['registered_paths']}/"
        f"{BASELINE_EXPECTED_COUNTS['selected_static_literals']}/"
        f"{BASELINE_EXPECTED_COUNTS['selected_static_markdown_documents']}/"
        f"{BASELINE_EXPECTED_COUNTS['directive_candidate_sentences']}/"
        f"{BASELINE_EXPECTED_COUNTS['subject_candidate_sentences']}; difference "
        f"{BASELINE_EXPECTED_COUNTS['registered_paths'] - PREVIOUSLY_RECORDED_COUNTS['registered_paths']} "
        "paths, "
        f"+{BASELINE_EXPECTED_COUNTS['selected_static_literals'] - PREVIOUSLY_RECORDED_COUNTS['selected_static_literals']} literals, "
        f"+{BASELINE_EXPECTED_COUNTS['directive_candidate_sentences'] - PREVIOUSLY_RECORDED_COUNTS['directive_candidate_sentences']} directive candidates, "
        f"+{BASELINE_EXPECTED_COUNTS['subject_candidate_sentences'] - PREVIOUSLY_RECORDED_COUNTS['subject_candidate_sentences']} subject candidates.",
        "",
        "Per-source counts (candidate sentences are source occurrences, not unique wording):",
        "file | Swift string literals | Markdown documents | directive candidates | subject candidates",
        "--- | ---: | ---: | ---: | ---:",
    ]
    for path in sorted(file_results):
        result = file_results[path]
        if not result.literals and not result.markdown_documents:
            continue
        lines.append(
            f"{path} | {result.literals} | {result.markdown_documents} | "
            f"{len(result.directive_candidates or [])} | {len(result.subject_candidates or [])}"
        )

    lines.extend(["", "Directive candidate occurrences (sentence wording omitted by default):"])
    directives = [c for p in sorted(file_results) for c in (file_results[p].directive_candidates or [])]
    for candidate in directives:
        detail = f"- {candidate.path}:{candidate.line} [{', '.join(candidate.cues)}]"
        if include_candidate_text:
            detail += f" {candidate.text}"
        lines.append(detail)

    lines.extend(["", "Explicit-subject candidate occurrences (sentence wording omitted by default):"])
    subjects = [c for p in sorted(file_results) for c in (file_results[p].subject_candidates or [])]
    for candidate in subjects:
        detail = f"- {candidate.path}:{candidate.line} [{', '.join(candidate.cues)}]"
        if include_candidate_text:
            detail += f" {candidate.text}"
        lines.append(detail)

    lines.extend(
        [
            "",
            "Limits: Swift comments are skipped; registered Swift selectors, tool-result functions, and complete registered Markdown documents are scanned.",
            "New UTF-8 text files and newly introduced heuristic candidate wording are checked against the batch-0 tree; unregistered changes fail closed.",
            "This does not discover every pre-existing omitted source, static text without heuristic cues, dynamic content, or non-UTF-8/binary payloads; manual route review remains necessary.",
            "Dynamic/user-authored content, runtime data, localized/generated text, provider payload transformations, and arbitrary tool output are not enumerable here.",
            "Keyword and subject matches are candidates only; they do not determine meaning, authority, or whether a string reaches a model on every branch.",
        ]
    )
    if unresolved:
        lines.extend(["", "UNRESOLVED SCAN / SOURCE REGISTRATION ISSUES (review before trusting this baseline):"])
        lines.extend(f"- {item}" for item in unresolved)
    if check_failures:
        lines.extend(["", "BASELINE GATE FAILURES:"])
        lines.extend(f"- {item}" for item in check_failures)
    return "\n".join(lines) + "\n"


def render_json(
    file_results: dict[str, FileResult],
    unresolved: list[str],
    head: str,
    metrics: dict[str, int],
    check_mode: str,
    check_failures: list[str],
    include_candidate_text: bool = False,
) -> str:
    def candidate_payload(candidate: Candidate) -> dict[str, object]:
        payload = asdict(candidate)
        if not include_candidate_text:
            payload.pop("text", None)
        return payload

    files = {}
    for path in sorted(file_results):
        result = file_results[path]
        if not result.literals and not result.markdown_documents:
            continue
        files[path] = {
            "literals": result.literals,
            "markdown_documents": result.markdown_documents,
            "directive_candidates": [candidate_payload(c) for c in (result.directive_candidates or [])],
            "subject_candidates": [candidate_payload(c) for c in (result.subject_candidates or [])],
        }
    payload = {
        "head": head,
        "output_warning": "Candidate sentence text is omitted by default. --include-candidate-text exposes original source text, which may be sensitive and must be reviewed before sharing.",
        "candidate_text_included": include_candidate_text,
        "expected_baseline_commit": EXPECTED_BASELINE_COMMIT,
        "expected_commit_matches": head == EXPECTED_BASELINE_COMMIT,
        "historical_comparison": {
            "note": "The difference includes additional source registrations and nested-interpolation parsing; it is not a source-only delta.",
            "previous_scan_counts": PREVIOUSLY_RECORDED_COUNTS,
            "current_baseline_counts": BASELINE_EXPECTED_COUNTS,
            "delta": {
                name: BASELINE_EXPECTED_COUNTS[name] - PREVIOUSLY_RECORDED_COUNTS[name]
                for name in BASELINE_EXPECTED_COUNTS
            },
        },
        **metrics,
        "baseline_gate": {
            "mode": check_mode,
            "passed": not check_failures and not unresolved,
            "candidate_ceilings": CANDIDATE_CEILINGS if check_mode == "candidate-ceilings" else None,
            "exact_counts": BASELINE_EXPECTED_COUNTS if check_mode == "exact-baseline" else None,
            "failures": check_failures,
        },
        "files": files,
        "unresolved": unresolved,
        "heuristic_limits": [
            "Swift comments are skipped; registered Swift selectors, tool-result functions, and complete registered Markdown documents are scanned.",
            "Outer interpolation values remain represented by a placeholder; static nested Swift string literals are inventoried separately, while dynamic values are not expanded.",
            "Candidate wording is omitted by default; the opt-in --include-candidate-text flag may expose sensitive source text.",
            "New UTF-8 text files and newly introduced heuristic candidate wording are checked against the batch-0 tree; unregistered changes fail closed.",
            "This does not discover every pre-existing omitted source, static text without heuristic cues, dynamic content, or non-UTF-8/binary payloads; manual route review remains necessary.",
            "Dynamic/user-authored content, runtime data, localized/generated text, provider payload transformations, and arbitrary tool output are not enumerable here.",
            "Keyword and subject matches are candidates only; they do not determine meaning, authority, or whether a string reaches a model on every branch.",
        ],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON instead of the review report")
    parser.add_argument(
        "--include-candidate-text",
        action="store_true",
        help="include matched source wording (may be sensitive; do not share without review)",
    )
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="repository root (default: current directory)")
    parser.add_argument(
        "--exact-baseline",
        action="store_true",
        help="require the exact batch-0 commit, counts, and clean src/ios tree",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    if not (root / "src/ios").is_dir() or not (root / "docs").is_dir():
        print("error: run from the repository root (or pass --root)", file=sys.stderr)
        return 2

    file_results, unresolved, head = collect(root)
    unresolved.extend(new_source_registration_issues(root, file_results))
    unresolved.extend(changed_candidate_issues(root, file_results))
    metrics = summarize(file_results)
    check_mode = "exact-baseline" if args.exact_baseline else "candidate-ceilings"
    check_failures = baseline_gate_failures(root, head, metrics, args.exact_baseline)
    if args.json:
        output = render_json(
            file_results, unresolved, head, metrics, check_mode, check_failures,
            include_candidate_text=args.include_candidate_text,
        )
    else:
        output = render_text(
            file_results, unresolved, head, metrics, check_mode, check_failures,
            include_candidate_text=args.include_candidate_text,
        )
    sys.stdout.write(output)
    if unresolved:
        return 2
    if check_failures:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
