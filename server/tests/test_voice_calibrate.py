# SPDX-License-Identifier: AGPL-3.0-or-later
from scripts.voice_calibrate import rank_against


def test_rank_against_sorts_desc_and_keeps_title_label():
    ref = [1.0, 0.0]
    rows = rank_against(
        ref,
        [
            ("A", "Speaker 1", [0.0, 1.0]),
            ("B", "Speaker 2", [1.0, 0.0]),
            ("C", "Speaker 1", [0.7, 0.7]),
        ],
    )
    assert [(round(s, 2), t, label) for s, t, label in rows] == [
        (1.0, "B", "Speaker 2"),
        (0.71, "C", "Speaker 1"),
        (0.0, "A", "Speaker 1"),
    ]
