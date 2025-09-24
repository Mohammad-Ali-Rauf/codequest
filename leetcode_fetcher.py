#!/usr/bin/env python3

import requests
import random
import json
import os
import sys
from datetime import date

# Directories for storing data and cache
DATA_DIR = os.path.expanduser("~/.local/share/leetcode_tracker")
CACHE_DIR = os.path.expanduser("~/.cache/leetcode_tracker")

# Ensure directories exist
os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(CACHE_DIR, exist_ok=True)

# File paths
SOLVED_FILE = os.path.join(DATA_DIR, "solved.json")
CACHE_FILE = os.path.join(CACHE_DIR, "daily.json")

# LeetCode GraphQL API endpoint
URL = "https://leetcode.com/graphql"

# GraphQL query to get all problems
QUERY = """
{
  problemsetQuestionList: questionList(categorySlug: "", filters: {}, limit: 10000) {
    questions: data {
      acRate
      difficulty
      frontendQuestionId: questionFrontendId
      paidOnly: isPaidOnly
      title
      titleSlug
    }
  }
}
"""

def load_cache():
    if os.path.exists(CACHE_FILE):
        with open(CACHE_FILE, "r") as f:
            data = json.load(f)
            if data["date"] == date.today().isoformat():
                return data["problems"]
    return None

def save_cache(problems):
    with open(CACHE_FILE, "w") as f:
        json.dump({"date": date.today().isoformat(), "problems": problems}, f, indent=2)

def get_random_unsolved_problems():
    # First, try to load cache
    cached = load_cache()
    if cached:
        return cached

    try:
        # Daily seed so problems are stable for the day
        today_seed = int(date.today().strftime("%Y%m%d"))
        random.seed(today_seed)

        # Load solved problems
        solved = load_solved()

        # Send request to LeetCode API
        response = requests.post(URL, json={"query": QUERY})
        response.raise_for_status()

        data = response.json()
        questions = data["data"]["problemsetQuestionList"]["questions"]

        # Filter out paid problems and solved ones
        solved_ids = {p["id"] for p in solved}
        free_problems = [
             q for q in questions
            if not q["paidOnly"] and q["frontendQuestionId"] not in solved_ids
        ]

        easy = [q for q in free_problems if q["difficulty"] == "Easy"]
        medium = [q for q in free_problems if q["difficulty"] == "Medium"]
        hard = [q for q in free_problems if q["difficulty"] == "Hard"]

        # Select one random problem from each difficulty
        selected_easy = random.choice(easy) if easy else None
        selected_medium = random.choice(medium) if medium else None
        selected_hard = random.choice(hard) if hard else None

        problems = {
            "easy": selected_easy,
            "medium": selected_medium,
            "hard": selected_hard,
        }

        # Save to cache
        save_cache(problems)

        return problems

    except Exception as e:
        print(f"Error fetching problems: {e}")
        return None

def display_problems(problems):
    if not problems:
        print("Failed to fetch problems.")
        return

    solved = load_solved()
    solved_ids = {p["id"] for p in solved}

    print("\n🎯 Your Daily LeetCode Challenge (Random Unsolved):\n")

    difficulty_icons = {
        "easy": "🟢",
        "medium": "🟡",
        "hard": "🔴",
    }

    for difficulty, problem in problems.items():
        if problem:
            solved_marker = " ✅" if problem["frontendQuestionId"] in solved_ids else ""
            print(f"{difficulty_icons[difficulty]} {difficulty.upper()}:")
            print(f"   ID: {problem['frontendQuestionId']}{solved_marker}")
            print(f"   Title: {problem['title']}")
            print(f"   Acceptance: {problem['acRate']:.1f}%")
            print(f"   Link: https://leetcode.com/problems/{problem['titleSlug']}/")
            print()
        else:
            print(f"❌ No {difficulty} problem found.")

def load_solved():
    if os.path.exists(SOLVED_FILE):
        with open(SOLVED_FILE, "r") as f:
            return json.load(f)  # list of dicts
    return []

def save_solved(solved):
    with open(SOLVED_FILE, "w") as f:
        json.dump(solved, f, indent=2)

def mark_as_done(problem_id):
    solved = load_solved()
    if any(p["id"] == problem_id for p in solved):
        print(f"⚠️ Problem {problem_id} is already marked as solved.")
        return

    # Always fetch full problem list for accurate info
    response = requests.post(URL, json={"query": QUERY})
    response.raise_for_status()
    all_problems = response.json()["data"]["problemsetQuestionList"]["questions"]

    match = next((q for q in all_problems if q["frontendQuestionId"] == problem_id), None)
    if not match:
        print(f"❌ Problem {problem_id} not found.")
        return

    solved.append({
        "id": match["frontendQuestionId"],
        "title": match["title"],
        "slug": match["titleSlug"],
        "difficulty": match["difficulty"]
    })
    save_solved(solved)
    print(f"✅ Problem {problem_id} ({match['title']}) marked as solved.")

def mark_as_incomplete(problem_id):
    solved = load_solved()
    new_solved = [p for p in solved if p["id"] != problem_id]
    if len(new_solved) == len(solved):
        print(f"⚠️ Problem {problem_id} was not marked as solved.")
    else:
        save_solved(new_solved)
        print(f"↩️ Problem {problem_id} marked as incomplete.")

def list_solved():
    solved = sorted(load_solved(), key=lambda p: int(p["id"]))
    if not solved:
        print("📂 No problems solved yet.")
        return

    print("\n📂 Solved Problems:\n")
    icons = {"Easy": "🟢", "Medium": "🟡", "Hard": "🔴"}
    for p in solved:
        icon = icons.get(p["difficulty"], "❓")
        print(f"{icon} [{p['id']}] {p['title']} ({p['difficulty']})")
        print(f"   🔗 https://leetcode.com/problems/{p['slug']}/\n")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  leetcode fetch")
        print("  leetcode markAsDone [id]")
        print("  leetcode markAsIncomplete [id]")
        print("  leetcode listSolved")
        sys.exit(1)

    command = sys.argv[1]

    if command == "fetch":
        print("Fetching your daily LeetCode problems...\n")
        problems = get_random_unsolved_problems()
        display_problems(problems)

    elif command == "markAsDone" and len(sys.argv) == 3:
        mark_as_done(sys.argv[2])

    elif command == "markAsIncomplete" and len(sys.argv) == 3:
        mark_as_incomplete(sys.argv[2])

    elif command == "listSolved":
        list_solved()

    else:
        print("❌ Invalid command or arguments.")
