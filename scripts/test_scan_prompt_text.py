"""Focused regression tests for the static prompt-text scanner."""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import scan_prompt_text as scanner


class ScannerRegressionTests(unittest.TestCase):
    def test_anthropic_oauth_system_prompt_property_is_scanned(self) -> None:
        path = "src/ios/Providers/Anthropic/AnthropicProvider.swift"
        source = 'static let claudeCodeSystemPrompt: String = "Please follow the fixture."'
        unresolved: list[str] = []

        selected = scanner.selected_literal_scopes(Path.cwd(), path, source, unresolved)
        _, literals = scanner.mask_non_code(source)
        candidates = scanner.candidates_in_file(path, source, selected)

        self.assertFalse(unresolved)
        self.assertEqual(
            selected,
            {literals[0].start: "property:claudeCodeSystemPrompt"},
        )
        self.assertEqual([candidate.text for candidate in candidates], ["Please follow the fixture."])

    def test_request_budget_image_placeholders_are_scanned(self) -> None:
        root = Path(__file__).resolve().parents[1]
        path = "src/ios/Agent/Chat/AIChatViewModel+RequestBudget.swift"
        source = (root / path).read_text(encoding="utf-8")
        unresolved: list[str] = []

        selected = scanner.selected_literal_scopes(root, path, source, unresolved)
        _, literals = scanner.mask_non_code(source)
        scanned_literals = [literal for literal in literals if literal.start in selected]
        candidates = scanner.candidates_in_file(path, source, selected)

        self.assertFalse(unresolved)
        self.assertEqual(len(scanned_literals), 2)
        self.assertEqual(set(selected.values()), {"function:elidedImagePlaceholder"})
        self.assertTrue(any("read_image" in literal.text for literal in scanned_literals))
        self.assertTrue(any("ask the user to re-attach" in literal.text for literal in scanned_literals))
        selected_candidates = [
            candidate
            for candidate in candidates
            if candidate.scan_range == "function:elidedImagePlaceholder"
        ]
        self.assertTrue(selected_candidates)
        self.assertEqual(
            {candidate.scan_range for candidate in selected_candidates},
            {"function:elidedImagePlaceholder"},
        )

    def test_feedback_directives_are_scanned_without_ui_labels(self) -> None:
        root = Path(__file__).resolve().parents[1]
        path = "src/ios/Views/Chat/MessageActionBar.swift"
        source = (root / path).read_text(encoding="utf-8")
        unresolved: list[str] = []

        selected = scanner.selected_literal_scopes(root, path, source, unresolved)
        _, literals = scanner.mask_non_code(source)
        scanned_literals = [literal for literal in literals if literal.start in selected]
        candidates = scanner.candidates_in_file(path, source, selected)
        scanned_text = [literal.text for literal in scanned_literals]

        self.assertFalse(unresolved)
        self.assertEqual(len(scanned_literals), 8)
        self.assertEqual(set(selected.values()), {"reminder:<system_runtime_feedback"})
        self.assertTrue(any('tag="brevity_control"' in text for text in scanned_text))
        self.assertTrue(any('tag="persona_correction"' in text for text in scanned_text))
        self.assertTrue(any('tag="emotional_connection"' in text for text in scanned_text))
        self.assertTrue(any('event="haptic_nudge"' in text for text in scanned_text))
        self.assertTrue(any('event="silence_directive"' in text for text in scanned_text))
        self.assertFalse(any("太长" in text or "快捷标签" in text for text in scanned_text))
        self.assertTrue(candidates)

    def test_duplicate_candidates_keep_occurrences_and_scan_range(self) -> None:
        source = 'let first = "Please check."\nlet second = "Please check."'
        _, literals = scanner.mask_non_code(source)
        ranges = {literal.start: "function:synthetic" for literal in literals}

        candidates = scanner.candidates_in_file("Synthetic.swift", source, ranges)
        self.assertEqual(len(candidates), 2)
        self.assertEqual({candidate.scan_range for candidate in candidates}, {"function:synthetic"})

        delta = scanner.candidate_occurrence_delta(candidates, candidates[:1])
        self.assertEqual(
            delta,
            {("Synthetic.swift", "function:synthetic", "Please check."): 1},
        )

    def test_interpolation_keeps_nested_string_boundaries_and_block_comments(self) -> None:
        source = r'''let nested = "prefix \(call(")")) suffix"
let commented = "prefix \(call(/* ) */ value)) suffix"'''

        _, literals = scanner.mask_non_code(source)

        self.assertEqual(
            [literal.text for literal in literals],
            ["prefix ⟪dynamic⟫ suffix", ")", "prefix ⟪dynamic⟫ suffix"],
        )

    def test_static_interpolation_string_is_scanned_without_dynamic_values_or_leak(self) -> None:
        source = r'''let message = "Prefix: \("Please call the tool.") suffix \(runtimeValue)"'''
        _, literals = scanner.mask_non_code(source)
        ranges = {literal.start: "function:synthetic" for literal in literals}
        candidates = scanner.candidates_in_file("Synthetic.swift", source, ranges)

        self.assertEqual(
            [literal.text for literal in literals],
            ["Prefix: ⟪dynamic⟫ suffix ⟪dynamic⟫", "Please call the tool."],
        )
        self.assertEqual([candidate.text for candidate in candidates], ["Please call the tool."])

        result = scanner.FileResult(literals=len(literals))
        result.directive_candidates.extend(candidates)
        files = {"Synthetic.swift": result}
        report = scanner.render_json(
            files, [], "synthetic-head", scanner.summarize(files), "candidate-ceilings", []
        )
        self.assertNotIn("Please call the tool.", report)

    def test_unresolved_interpolation_fails_closed(self) -> None:
        source = r'''let broken = "value \(call("inner")"'''

        with self.assertRaises(scanner.SwiftScanError):
            scanner.mask_non_code(source)

    def test_unterminated_block_comment_makes_cli_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "src/ios/Synthetic.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "func sample() {\n    /* unterminated\n}\n",
                encoding="utf-8",
            )
            (root / "docs").mkdir()
            output = io.StringIO()

            def fake_git(command: list[str], **_kwargs: object) -> str:
                if command[1] == "rev-parse":
                    return "synthetic-head\n"
                if command[1] in {"ls-tree", "diff"}:
                    return ""
                raise AssertionError("unexpected synthetic git command")

            with (
                mock.patch.object(
                    scanner,
                    "SYMBOL_SCOPES",
                    {"src/ios/Synthetic.swift": {"function": ["sample"]}},
                ),
                mock.patch.object(scanner, "REMINDER_MARKER_SCOPES", {}),
                mock.patch.object(scanner, "MARKDOWN_DOCUMENT_SOURCES", ()),
                mock.patch.object(scanner, "TOOL_RESULT_ROOTS", ()),
                mock.patch.object(scanner.subprocess, "check_output", side_effect=fake_git),
                mock.patch.object(
                    scanner.sys,
                    "argv",
                    ["scan_prompt_text.py", "--root", str(root)],
                ),
                contextlib.redirect_stdout(output),
            ):
                exit_code = scanner.main()

        report = output.getvalue()
        self.assertEqual(exit_code, 2)
        self.assertIn("Baseline gate: FAIL", report)
        self.assertIn(
            "cannot safely scan Swift source src/ios/Synthetic.swift: "
            "unterminated Swift block comment at line 2",
            report,
        )
        self.assertNotIn("Baseline gate: PASS", report)

    def test_candidate_text_is_omitted_unless_explicitly_requested(self) -> None:
        result = scanner.FileResult(literals=1)
        result.directive_candidates.append(
            scanner.Candidate(
                "Synthetic.swift",
                3,
                "synthetic-marker",
                ("synthetic-cue",),
                "function:synthetic",
                0,
            )
        )
        files = {"Synthetic.swift": result}
        metrics = scanner.summarize(files)

        json_report = scanner.render_json(
            files, [], "synthetic-head", metrics, "candidate-ceilings", []
        )
        text_report = scanner.render_text(
            files, [], "synthetic-head", metrics, "candidate-ceilings", []
        )
        self.assertNotIn("synthetic-marker", json_report)
        self.assertNotIn("synthetic-marker", text_report)
        self.assertIn("Synthetic.swift", json_report)
        self.assertIn("synthetic-cue", json_report)
        self.assertIn("may be sensitive", text_report)
        self.assertIn("may be sensitive", json.loads(json_report)["output_warning"])
        self.assertNotIn("synthetic-marker", json.loads(json_report)["files"]["Synthetic.swift"]["directive_candidates"][0])

        raw_report = scanner.render_json(
            files,
            [],
            "synthetic-head",
            metrics,
            "candidate-ceilings",
            [],
            include_candidate_text=True,
        )
        self.assertEqual(
            json.loads(raw_report)["files"]["Synthetic.swift"]["directive_candidates"][0]["text"],
            "synthetic-marker",
        )
        raw_text_report = scanner.render_text(
            files,
            [],
            "synthetic-head",
            metrics,
            "candidate-ceilings",
            [],
            include_candidate_text=True,
        )
        self.assertIn("synthetic-marker", raw_text_report)
        self.assertIn("may be sensitive", raw_text_report)

    def test_unreadable_source_reports_path_and_cli_exits_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "src/ios/Synthetic.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text('func sample() { let text = "Please check." }', encoding="utf-8")
            (root / "docs").mkdir()
            output = io.StringIO()

            with (
                mock.patch.object(
                    scanner,
                    "SYMBOL_SCOPES",
                    {"src/ios/Synthetic.swift": {"function": ["sample"]}},
                ),
                mock.patch.object(scanner, "REMINDER_MARKER_SCOPES", {}),
                mock.patch.object(scanner, "MARKDOWN_DOCUMENT_SOURCES", ()),
                mock.patch.object(scanner, "TOOL_RESULT_ROOTS", ()),
                mock.patch.object(
                    scanner.Path,
                    "read_text",
                    side_effect=PermissionError("synthetic-secret-must-not-appear"),
                ),
                mock.patch.object(scanner.sys, "argv", ["scan_prompt_text.py", "--root", str(root)]),
                contextlib.redirect_stdout(output),
            ):
                exit_code = scanner.main()

        report = output.getvalue()
        self.assertEqual(exit_code, 2)
        self.assertIn("cannot read UTF-8 source src/ios/Synthetic.swift: PermissionError", report)
        self.assertNotIn("synthetic-secret-must-not-appear", report)

    def test_baseline_decode_failure_does_not_echo_exception_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source_path = root / "src/ios/Synthetic.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text('func sample() { let text = "Please check." }', encoding="utf-8")
            relative_path = "src/ios/Synthetic.swift"

            def fake_check_output(command: list[str], **_kwargs: object) -> str:
                if command[1] in {"ls-tree", "diff"}:
                    return relative_path + "\n"
                if command[1] == "show":
                    raise UnicodeDecodeError(
                        "utf-8", b"\xff", 0, 1, "synthetic-secret-must-not-appear"
                    )
                raise AssertionError("unexpected synthetic git command")

            with mock.patch.object(
                scanner.subprocess, "check_output", side_effect=fake_check_output
            ):
                issues = scanner.changed_candidate_issues(root, {})

        self.assertIn(
            "cannot read baseline source src/ios/Synthetic.swift: UnicodeDecodeError",
            issues,
        )
        self.assertFalse(any("synthetic-secret-must-not-appear" in issue for issue in issues))


if __name__ == "__main__":
    unittest.main()
