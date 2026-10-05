import unittest

from download_stats import daily


def row(id, count, created_at="2026-01-01T00:00:00Z", asset="appcast.xml"):
    return {"id": id, "count": count, "created_at": created_at, "tag": "appcast", "asset": asset}


class DailyTests(unittest.TestCase):
    def test_first_snapshot_is_only_a_baseline(self):
        self.assertEqual(daily([("2026-10-01T00:05:00Z", [row(1, 40)])]), {})

    def test_interval_is_dated_by_its_start(self):
        result = daily([
            ("2026-10-01T00:05:00Z", [row(1, 40)]),
            ("2026-10-02T00:30:00Z", [row(1, 47)]),
        ])
        self.assertEqual(result, {("2026-10-01", "appcast", "appcast.xml"): 7})

    def test_clobber_keeps_the_old_assets_final_count_and_counts_the_new_one_from_zero(self):
        result = daily([
            ("2026-10-01T00:05:00Z", [row(1, 40)]),
            ("2026-10-01T12:00:00Z", [row(1, 45)]),  # pre-clobber snapshot
            ("2026-10-02T00:05:00Z", [row(2, 3, created_at="2026-10-01T12:01:00Z")]),
        ])
        self.assertEqual(result, {("2026-10-01", "appcast", "appcast.xml"): 8})

    def test_assets_are_kept_apart(self):
        result = daily([
            ("2026-10-01T00:05:00Z", [row(1, 0), row(9, 5, asset="a.dmg")]),
            ("2026-10-02T00:05:00Z", [row(1, 2), row(9, 6, asset="a.dmg")]),
        ])
        self.assertEqual(result, {("2026-10-01", "appcast", "appcast.xml"): 2,
                                  ("2026-10-01", "appcast", "a.dmg"): 1})


if __name__ == "__main__":
    unittest.main()
