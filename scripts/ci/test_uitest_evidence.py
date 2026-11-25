"""Tests for uitest_evidence.py's reading of xcresulttool's test tree."""

import unittest

from uitest_evidence import failures


def case(name, result, *messages):
    return {
        "nodeType": "Test Case",
        "nodeIdentifier": name,
        "result": result,
        "children": [{"nodeType": "Failure Message", "name": m} for m in messages],
    }


class FailuresTests(unittest.TestCase):
    def test_finds_failed_cases_at_any_depth_with_their_messages(self):
        tree = [
            {
                "nodeType": "Test Plan",
                "children": [
                    {
                        "nodeType": "Test Suite",
                        "children": [
                            case("A/testPasses()", "Passed"),
                            case("A/testFails()", "Failed", "first", "second"),
                        ],
                    },
                    case("B/testSkips()", "Skipped"),
                    case("B/testFails()", "Failed", "only"),
                ],
            }
        ]
        self.assertEqual(
            failures(tree), [("A/testFails()", "first\nsecond"), ("B/testFails()", "only")]
        )

    def test_none_failed_is_empty(self):
        self.assertEqual(failures([case("A/testPasses()", "Passed")]), [])


if __name__ == "__main__":
    unittest.main()
