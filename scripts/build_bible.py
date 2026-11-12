#!/usr/bin/env python3
"""Builds the bundled KJV text and book catalog for ScriptoriKit.

Usage:
    python3 scripts/build_bible.py [--source DIR]

Without --source, the public-domain KJV is downloaded from
https://github.com/aruljohn/Bible-kjv (one JSON file per book). Outputs:

    ScriptoriKit/Sources/ScriptoriKit/Resources/Bible/KJV/<OSIS>.json
        {"id", "name", "chapters": [[verse text, ...], ...]}
    ScriptoriKit/Sources/ScriptoriKit/Resources/Books.json
        catalog with category, blurb, themes, intents and reading time per book

Chapter guides (Resources/Guides/<OSIS>.json) are hand-authored and not touched here.
"""

import argparse
import json
import pathlib
import urllib.parse
import urllib.request

SOURCE_URL = "https://raw.githubusercontent.com/aruljohn/Bible-kjv/master/{name}.json"
ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "ScriptoriKit" / "Sources" / "ScriptoriKit" / "Resources"
WORDS_PER_MINUTE = 200

# Intents match `ReadingIntent` in ScriptoriKit: peace, habit, understand, hardSeason, grow.
# Level: 1 = good first book, 2 = some background helps, 3 = best with experience.
# (osis, name, category, palette, level, intents, themes, blurb)
BOOKS = [
    ("GEN", "Genesis", "Law", "dawn", 1, ["understand", "habit"], ["Creation", "Promise", "Family"], "Where everything begins: creation, the first families, and God's promise to Abraham."),
    ("EXO", "Exodus", "Law", "ember", 2, ["understand", "hardSeason"], ["Deliverance", "Covenant", "Presence"], "God hears a people in slavery, leads them out, and meets them in the wilderness."),
    ("LEV", "Leviticus", "Law", "paper", 3, ["understand"], ["Holiness", "Worship", "Atonement"], "Instructions for worship and holy living for a people God dwells among."),
    ("NUM", "Numbers", "Law", "dusk", 3, ["understand"], ["Wilderness", "Faithfulness", "Guidance"], "Forty years in the wilderness: grumbling, grace, and God's steady leading."),
    ("DEU", "Deuteronomy", "Law", "meadow", 2, ["understand", "grow"], ["Remembering", "Love", "Obedience"], "Moses' farewell sermons, calling a new generation to love God with all their heart."),
    ("JOS", "Joshua", "History", "ember", 2, ["grow", "hardSeason"], ["Courage", "Promise", "Faithfulness"], "Be strong and of good courage: Israel enters the promised land."),
    ("JDG", "Judges", "History", "dusk", 3, ["understand"], ["Cycles", "Deliverance", "Mercy"], "A restless people, a patient God, and a series of unlikely deliverers."),
    ("RUT", "Ruth", "History", "meadow", 1, ["hardSeason", "peace"], ["Loyalty", "Kindness", "Redemption"], "A short story of loss, loyalty, and quiet redemption in hard times."),
    ("1SA", "1 Samuel", "History", "dawn", 2, ["understand", "grow"], ["Calling", "Humility", "The heart"], "From Hannah's prayer to David's rise: God looks on the heart."),
    ("2SA", "2 Samuel", "History", "ember", 2, ["understand"], ["Kingship", "Failure", "Repentance"], "King David's reign, his great failure, and God's enduring promise."),
    ("1KI", "1 Kings", "History", "ocean", 2, ["understand"], ["Wisdom", "Idolatry", "Prophets"], "Solomon's wisdom, a divided kingdom, and Elijah's bold faith."),
    ("2KI", "2 Kings", "History", "dusk", 3, ["understand"], ["Faithfulness", "Judgment", "Hope"], "Kings rise and fall while prophets call the people back to God."),
    ("1CH", "1 Chronicles", "History", "paper", 3, ["understand"], ["Worship", "Heritage", "Promise"], "Israel's story retold with David and worship at the center."),
    ("2CH", "2 Chronicles", "History", "paper", 3, ["understand"], ["Revival", "Prayer", "Temple"], "The temple, the kings of Judah, and the revivals that followed humble prayer."),
    ("EZR", "Ezra", "History", "meadow", 2, ["grow"], ["Return", "Rebuilding", "Scripture"], "Exiles return home to rebuild the temple and recommit to God's word."),
    ("NEH", "Nehemiah", "History", "ember", 2, ["grow", "habit"], ["Prayer", "Rebuilding", "Perseverance"], "A prayerful leader rebuilds Jerusalem's walls against the odds."),
    ("EST", "Esther", "History", "dusk", 1, ["hardSeason", "grow"], ["Courage", "Providence", "Purpose"], "For such a time as this: a queen risks everything for her people."),
    ("JOB", "Job", "Wisdom", "ocean", 2, ["hardSeason"], ["Suffering", "Honesty", "Trust"], "An honest wrestling with suffering, and the God who answers from the whirlwind."),
    ("PSA", "Psalms", "Psalms", "meadow", 1, ["peace", "hardSeason", "habit"], ["Prayer", "Comfort", "Praise"], "150 songs and prayers for every season of the heart, from lament to praise."),
    ("PRO", "Proverbs", "Wisdom", "dawn", 1, ["habit", "grow"], ["Wisdom", "Words", "Character"], "Short, practical wisdom for everyday choices, one chapter for each day of the month."),
    ("ECC", "Ecclesiastes", "Wisdom", "paper", 2, ["hardSeason", "understand"], ["Meaning", "Seasons", "Contentment"], "A searching look at life's meaning: a time for everything under the sun."),
    ("SNG", "Song of Solomon", "Wisdom", "ember", 3, ["understand"], ["Love", "Delight", "Devotion"], "A poetic celebration of love and longing."),
    ("ISA", "Isaiah", "Prophets", "ocean", 2, ["hardSeason", "understand"], ["Comfort", "Holiness", "Messiah"], "Visions of judgment and sweeping comfort: they that wait upon the LORD shall renew their strength."),
    ("JER", "Jeremiah", "Prophets", "dusk", 3, ["hardSeason"], ["Lament", "Faithfulness", "New covenant"], "A weeping prophet speaks hard truth and a promise of a new heart."),
    ("LAM", "Lamentations", "Prophets", "dusk", 2, ["hardSeason"], ["Grief", "Mercy", "Hope"], "Five poems of grief, with hope at the center: his compassions fail not."),
    ("EZK", "Ezekiel", "Prophets", "ocean", 3, ["understand"], ["Glory", "Restoration", "New heart"], "Strange visions, dry bones, and the promise of a new spirit."),
    ("DAN", "Daniel", "Prophets", "ember", 2, ["grow", "hardSeason"], ["Faithfulness", "Courage", "Sovereignty"], "Staying faithful in a foreign land, from the lions' den to visions of the future."),
    ("HOS", "Hosea", "Prophets", "dusk", 2, ["understand"], ["Faithful love", "Return", "Mercy"], "A prophet's marriage pictures God's relentless love for an unfaithful people."),
    ("JOL", "Joel", "Prophets", "ember", 2, ["understand"], ["Repentance", "Restoration", "Spirit"], "After disaster, a call to return and a promise of the Spirit poured out."),
    ("AMO", "Amos", "Prophets", "paper", 2, ["understand", "grow"], ["Justice", "Worship", "Righteousness"], "Let justice roll down: a shepherd confronts comfortable religion."),
    ("OBA", "Obadiah", "Prophets", "paper", 3, ["understand"], ["Pride", "Justice", "Kingdom"], "The shortest Old Testament book, on pride and God's justice."),
    ("JON", "Jonah", "Prophets", "ocean", 1, ["grow", "understand"], ["Second chances", "Mercy", "Calling"], "A reluctant prophet, a great fish, and a God whose mercy is wider than ours."),
    ("MIC", "Micah", "Prophets", "meadow", 2, ["grow"], ["Justice", "Mercy", "Humility"], "Do justly, love mercy, and walk humbly with thy God."),
    ("NAM", "Nahum", "Prophets", "dusk", 3, ["understand"], ["Justice", "Refuge", "Sovereignty"], "God's justice toward Nineveh, and a stronghold in the day of trouble."),
    ("HAB", "Habakkuk", "Prophets", "ocean", 2, ["hardSeason"], ["Questions", "Waiting", "Trust"], "A prophet brings honest questions to God and learns to rejoice anyway."),
    ("ZEP", "Zephaniah", "Prophets", "paper", 3, ["understand"], ["Day of the LORD", "Humility", "Joy"], "Warning and hope: the LORD rejoices over thee with singing."),
    ("HAG", "Haggai", "Prophets", "ember", 2, ["grow", "habit"], ["Priorities", "Rebuilding", "Presence"], "Consider your ways: a short call to put first things first."),
    ("ZEC", "Zechariah", "Prophets", "dawn", 3, ["understand"], ["Restoration", "Visions", "King"], "Night visions and promises of a coming, humble king."),
    ("MAL", "Malachi", "Prophets", "paper", 2, ["understand"], ["Faithfulness", "Worship", "Preparation"], "The Old Testament's closing word, calling hearts back to God."),
    ("MAT", "Matthew", "Gospels", "dawn", 1, ["understand", "grow"], ["Kingdom", "Teaching", "Fulfillment"], "Jesus as the promised King, including the Sermon on the Mount."),
    ("MRK", "Mark", "Gospels", "ember", 1, ["understand", "habit"], ["Action", "Discipleship", "The cross"], "The shortest, fastest-moving account of Jesus' life. A great first book."),
    ("LUK", "Luke", "Gospels", "meadow", 1, ["understand", "peace"], ["Compassion", "Outsiders", "Joy"], "A careful account of Jesus' life, full of grace for the overlooked."),
    ("JHN", "John", "Gospels", "ocean", 1, ["peace", "understand", "grow"], ["Belief", "Life", "Love"], "Written that ye might believe: the life of Jesus through signs and conversations."),
    ("ACT", "Acts", "History", "ember", 1, ["grow", "understand"], ["Spirit", "Church", "Witness"], "The early church spreads from Jerusalem to Rome, powered by the Spirit."),
    ("ROM", "Romans", "Letters", "dusk", 2, ["understand", "grow"], ["Grace", "Faith", "New life"], "Paul's fullest explanation of the gospel: grace, faith, and life in the Spirit."),
    ("1CO", "1 Corinthians", "Letters", "dawn", 2, ["grow"], ["Love", "Unity", "Resurrection"], "Practical help for a messy church, including the great chapter on love."),
    ("2CO", "2 Corinthians", "Letters", "ocean", 2, ["hardSeason", "grow"], ["Weakness", "Comfort", "Generosity"], "Strength made perfect in weakness, from Paul's most personal letter."),
    ("GAL", "Galatians", "Letters", "ember", 2, ["grow", "understand"], ["Freedom", "Grace", "Spirit"], "A short, passionate letter about freedom in Christ and the fruit of the Spirit."),
    ("EPH", "Ephesians", "Letters", "ocean", 1, ["grow", "peace"], ["Identity", "Grace", "Unity"], "Who you are in Christ, and how to walk in love."),
    ("PHP", "Philippians", "Letters", "ember", 1, ["peace", "hardSeason", "habit"], ["Joy", "Peace", "Contentment"], "A joyful letter written from prison: peace over anxiety and contentment in every state."),
    ("COL", "Colossians", "Letters", "meadow", 1, ["grow", "understand"], ["Christ above all", "New self", "Gratitude"], "Christ at the center of everything, and a life that flows from him."),
    ("1TH", "1 Thessalonians", "Letters", "dawn", 1, ["grow", "hardSeason"], ["Hope", "Encouragement", "Holiness"], "Warm encouragement for a young church: rejoice evermore, pray without ceasing."),
    ("2TH", "2 Thessalonians", "Letters", "dusk", 2, ["grow"], ["Perseverance", "Hope", "Faithfulness"], "Stand firm and keep doing good while you wait."),
    ("1TI", "1 Timothy", "Letters", "paper", 2, ["grow"], ["Leadership", "Godliness", "Contentment"], "Paul mentors a young leader on faith, character, and community."),
    ("2TI", "2 Timothy", "Letters", "ember", 2, ["grow", "hardSeason"], ["Endurance", "Scripture", "Legacy"], "Paul's last letter: fight the good fight, finish the course, keep the faith."),
    ("TIT", "Titus", "Letters", "paper", 2, ["grow"], ["Good works", "Grace", "Sound teaching"], "Grace that teaches us to live well, in three short chapters."),
    ("PHM", "Philemon", "Letters", "meadow", 1, ["grow"], ["Reconciliation", "Brotherhood", "Grace"], "A one-chapter letter asking a master to welcome back a runaway as a brother."),
    ("HEB", "Hebrews", "Letters", "dusk", 2, ["grow", "hardSeason"], ["Faith", "Endurance", "Jesus our priest"], "Jesus, greater than all, and a great cloud of witnesses cheering you on."),
    ("JAS", "James", "Letters", "dawn", 1, ["habit", "grow"], ["Faith in action", "Wisdom", "Words"], "Practical, punchy wisdom: be doers of the word, not hearers only."),
    ("1PE", "1 Peter", "Letters", "ocean", 1, ["hardSeason", "peace"], ["Hope", "Suffering", "Identity"], "Living hope for people under pressure: cast all your care upon him."),
    ("2PE", "2 Peter", "Letters", "dusk", 2, ["grow"], ["Growth", "Truth", "Patience"], "Add to your faith virtue, knowledge, and love, and grow in grace."),
    ("1JN", "1 John", "Letters", "meadow", 1, ["peace", "grow"], ["Love", "Assurance", "Light"], "God is love: a gentle letter on assurance and loving one another."),
    ("2JN", "2 John", "Letters", "paper", 2, ["grow"], ["Truth", "Love", "Discernment"], "A one-chapter note on walking in truth and love."),
    ("3JN", "3 John", "Letters", "paper", 2, ["grow"], ["Hospitality", "Faithfulness", "Good example"], "A one-chapter note commending hospitality and faithfulness."),
    ("JUD", "Jude", "Letters", "ember", 2, ["grow"], ["Contending", "Mercy", "Keeping"], "Keep yourselves in the love of God, kept by him who is able."),
    ("REV", "Revelation", "Prophecy", "dusk", 3, ["understand", "hardSeason"], ["Victory", "Worship", "New creation"], "Visions of the risen Christ and a new heaven and earth where tears are wiped away."),
]

OLD_TESTAMENT_COUNT = 39


def load_source(name: str, source: pathlib.Path | None) -> dict:
    if source:
        return json.loads((source / f"{name.replace(' ', '')}.json").read_text())
    url = SOURCE_URL.format(name=urllib.parse.quote(name.replace(" ", "")))
    with urllib.request.urlopen(url) as response:
        return json.loads(response.read())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=pathlib.Path, help="Directory with aruljohn/Bible-kjv book files")
    args = parser.parse_args()

    out_dir = RESOURCES / "Bible" / "KJV"
    out_dir.mkdir(parents=True, exist_ok=True)
    catalog = []
    total_chapters = 0

    for index, (osis, name, category, palette, level, intents, themes, blurb) in enumerate(BOOKS):
        source = load_source(name, args.source)
        chapters = []
        for number, chapter in enumerate(sorted(source["chapters"], key=lambda c: int(c["chapter"])), start=1):
            assert int(chapter["chapter"]) == number, f"{name} is missing chapter {number}"
            verses = sorted(chapter["verses"], key=lambda v: int(v["verse"]))
            numbers = [int(v["verse"]) for v in verses]
            assert numbers == list(range(1, len(verses) + 1)), f"{name} {number} has gaps"
            chapters.append([" ".join(v["text"].split()) for v in verses])

        words = sum(len(text.split()) for chapter in chapters for text in chapter)
        minutes = max(1, round(words / len(chapters) / WORDS_PER_MINUTE))

        (out_dir / f"{osis}.json").write_text(
            json.dumps({"id": osis, "name": name, "chapters": chapters}, ensure_ascii=False, separators=(",", ":"))
        )
        catalog.append({
            "id": osis,
            "name": name,
            "testament": "old" if index < OLD_TESTAMENT_COUNT else "new",
            "category": category,
            "palette": palette,
            "level": level,
            "chapterCount": len(chapters),
            "minutesPerDay": minutes,
            "blurb": blurb,
            "themes": themes,
            "intents": intents,
        })
        total_chapters += len(chapters)
        print(f"{osis:4} {name:16} {len(chapters):3} chapters, ~{minutes} min/day")

    assert len(catalog) == 66, len(catalog)
    assert total_chapters == 1189, total_chapters
    (RESOURCES / "Books.json").write_text(
        json.dumps({"translation": "KJV", "books": catalog}, ensure_ascii=False, indent=2) + "\n"
    )
    print(f"Wrote {len(catalog)} books, {total_chapters} chapters")


if __name__ == "__main__":
    main()
