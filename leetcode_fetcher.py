#!/usr/bin/env python3

import requests
import random
import json
import os
import sys
from datetime import date

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

SOLVED_FILE = "solved.json"


def load_solved():
    if os.path.exists(SOLVED_FILE):
        with open(SOLVED_FILE, "r") as f:
            return set(json.load(f))
    return set()


def save_solved(solved):
    with open(SOLVED_FILE, "w") as f:
        json.dump(list(solved), f, indent=2)


def get_random_unsolved_problems():
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
        free_problems = [
            q
            for q in questions
            if not q["paidOnly"] and q["frontendQuestionId"] not in solved
        ]

        easy = [q for q in free_problems if q["difficulty"] == "Easy"]
        medium = [q for q in free_problems if q["difficulty"] == "Medium"]
        hard = [q for q in free_problems if q["difficulty"] == "Hard"]

        # Select one random problem from each difficulty
        selected_easy = random.choice(easy) if easy else None
        selected_medium = random.choice(medium) if medium else None
        selected_hard = random.choice(hard) if hard else None

        return {
            "easy": selected_easy,
            "medium": selected_medium,
            "hard": selected_hard,
        }

    except Exception as e:
        print(f"Error fetching problems: {e}")
        return None


def display_problems(problems):
    if not problems:
        print("Failed to fetch problems.")
        return

    print("\n🎯 Your Daily LeetCode Challenge (Random Unsolved):\n")

    difficulty_icons = {
        "easy": "🟢",
        "medium": "🟡",
        "hard": "🔴",
    }

    for difficulty, problem in problems.items():
        if problem:
            print(f"{difficulty_icons[difficulty]} {difficulty.upper()}:")
            print(f"   ID: {problem['frontendQuestionId']}")
            print(f"   Title: {problem['title']}")
            print(f"   Acceptance: {problem['acRate']:.1f}%")
            print(f"   Link: https://leetcode.com/problems/{problem['titleSlug']}/")
            print()
        else:
            print(f"❌ No {difficulty} problem found.")


def mark_as_done(problem_id):
    solved = load_solved()
    if problem_id in solved:
        print(f"⚠️ Problem {problem_id} is already marked as solved.")
    else:
        solved.add(problem_id)
        save_solved(solved)
        print(f"✅ Problem {problem_id} marked as solved.")


def mark_as_incomplete(problem_id):
    solved = load_solved()
    if problem_id in solved:
        solved.remove(problem_id)
        save_solved(solved)
        print(f"↩️ Problem {problem_id} marked as incomplete.")
    else:
        print(f"⚠️ Problem {problem_id} was not marked as solved.")


def list_solved():
    solved = sorted(load_solved(), key=int)
    if not solved:
        print("📂 No problems solved yet.")
    else:
        print("\n📂 Solved Problems:\n")
        for pid in solved:
            print(f"   - {pid}")


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
