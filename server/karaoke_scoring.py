"""Deciding which YouTube results are actually karaoke tracks.

Search alone isn't enough: a query for a song plus "karaoke" happily returns the
original recording, a live performance, and half a dozen covers. Since the app
plays these back untouched, putting a track with vocals in front of someone who
wanted an instrumental is the one failure that really matters — so scoring leans
towards rejecting rather than guessing.

Keywords are language-specific on purpose. KTV is a Chinese, Korean and Japanese
habit as much as an English one, and the useful words don't translate: a Korean
karaoke upload says "MR", a Chinese one says 伴奏, and neither says "karaoke".
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# Unambiguous "this is an instrumental" markers.
STRONG_POSITIVE = [
    # Chinese
    "伴奏", "ktv", "卡拉ok", "卡拉OK", "消音", "無人聲", "无人声", "去人聲", "去人声",
    # Japanese
    "カラオケ", "オフボーカル", "オフヴォーカル",
    # Korean
    "노래방",
    # English
    "karaoke", "instrumental", "off vocal", "offvocal", "backing track",
    "minus one", "sing along", "singalong",
]

# Suggestive but not conclusive.
WEAK_POSITIVE = [
    "導唱", "导唱",        # guide vocal: quiet vocal left in, still singable
    "純音樂", "纯音乐",
    "no vocal", "without vocals", "vocal removed",
]

# Markers that the track has the original singer on it, or isn't a studio track.
STRONG_NEGATIVE = [
    # Chinese
    "原唱", "翻唱", "現場", "现场", "演唱會", "演唱会", "直播",
    # Japanese
    "歌ってみた",
    # English
    "cover", "live", "reaction", "react", "lesson", "tutorial",
    "official video", "official mv", "music video", "behind the scenes",
]

WEAK_NEGATIVE = [
    "remix", "mashup", "nightcore", "sped up", "slowed",
    "teaser", "trailer", "preview", "shorts",
    # Compilations: karaoke, but an hour of it, and not the song you asked for.
    "medley", "compilation", "nonstop", "non-stop", "連唱", "连唱", "串燒", "串烧",
]

# "MR" is the standard Korean tag for an instrumental, but it's also a word.
# Require it standing alone and capitalised, so "Mr. Brightside" doesn't match.
MR_TAG = re.compile(r"(?:^|[\s\[\(\-_|/])MR(?:$|[\s\]\)\-_|/])")

# Channels whose whole output is karaoke are worth a nudge on their own.
CHANNEL_HINTS = ["karaoke", "ktv", "伴奏", "노래방", "カラオケ", "sing king", "zzang"]


@dataclass
class Scored:
    score: int
    confidence: str          # "high" | "medium" | "low"
    reasons: list[str]


def score_result(title: str, channel: str = "", duration: float | None = None) -> Scored:
    """Rank one search result on how likely it is to be a usable karaoke track."""
    haystack = f" {title.lower()} "
    channel_lower = (channel or "").lower()
    score = 0
    reasons: list[str] = []

    for keyword in STRONG_POSITIVE:
        if keyword.lower() in haystack:
            score += 4
            reasons.append(f"+{keyword}")
            break

    for keyword in WEAK_POSITIVE:
        if keyword.lower() in haystack:
            score += 2
            reasons.append(f"+{keyword}")
            break

    if MR_TAG.search(title):
        score += 3
        reasons.append("+MR")

    for keyword in STRONG_NEGATIVE:
        if keyword.lower() in haystack:
            score -= 5
            reasons.append(f"-{keyword}")
            break

    for keyword in WEAK_NEGATIVE:
        if keyword.lower() in haystack:
            score -= 2
            reasons.append(f"-{keyword}")
            break

    if any(hint in channel_lower for hint in CHANNEL_HINTS):
        score += 2
        reasons.append("+channel")

    # A karaoke track runs about as long as the song. Anything very short is a
    # clip, anything very long is a compilation or a livestream.
    if duration is not None:
        if duration < 60:
            score -= 3
            reasons.append("-short")
        elif duration > 900:
            # Well past any single song: a compilation, a livestream, or an
            # album rip. Heavy enough to sink an otherwise-perfect title.
            score -= 6
            reasons.append("-long")

    if score >= 6:
        confidence = "high"
    elif score >= 3:
        confidence = "medium"
    else:
        confidence = "low"

    return Scored(score=score, confidence=confidence, reasons=reasons)


def search_queries(song: str) -> list[str]:
    """Query variants to try, so one search covers the common tagging habits.

    Ordered by how specific they are; results are merged and de-duplicated by
    video id, keeping the best score.
    """
    song = song.strip()
    return [
        f"{song} 伴奏 KTV",
        f"{song} karaoke instrumental",
        f"{song} 노래방 MR",
        f"{song} カラオケ オフボーカル",
    ]
