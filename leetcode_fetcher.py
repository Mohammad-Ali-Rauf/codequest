#!/usr/bin/env python3

import requests
import random
import json
import os
import time
import sys
from datetime import date, timedelta, datetime
from typing import Dict, List, Optional, Any

# =============================================================================
# CONSTANTS AND CONFIGURATION
# =============================================================================

# Directory paths for data and cache storage
DATA_DIR = os.path.expanduser("~/.local/share/leetcode_tracker")
CACHE_DIR = os.path.expanduser("~/.cache/leetcode_tracker")

# File paths
SOLVED_FILE = os.path.join(DATA_DIR, "solved.json")
CACHE_FILE = os.path.join(CACHE_DIR, "daily.json")
ALL_PROBLEMS_CACHE = os.path.join(CACHE_DIR, "all_problems.json")
PROFILE_FILE = os.path.join(DATA_DIR, "profile.json")
GOALS_FILE = os.path.join(DATA_DIR, "goals.json")

# Goal types
class GoalType:
    TOTAL_SOLVED = "total_solved"
    DAILY_STREAK = "daily_streak" 
    DIFFICULTY_COUNT = "difficulty_count"
    WEEKLY_TARGET = "weekly_target"

# Goal status
class GoalStatus:
    ACTIVE = "active"
    COMPLETED = "completed"
    FAILED = "failed"

# LeetCode GraphQL API endpoint
LEETCODE_URL = "https://leetcode.com/graphql"

# GraphQL query to get all problems
ALL_PROBLEMS_QUERY = """
{
  problemsetQuestionList: questionList(categorySlug: "", filters: {}, limit: 500) {
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

# Difficulty configuration
DIFFICULTIES = ["easy", "medium", "hard"]
DIFFICULTY_ICONS = {"easy": "🟢", "medium": "🟡", "hard": "🔴"}
DIFFICULTY_COLORS = {"Easy": "🟢", "Medium": "🟡", "Hard": "🔴"}

# Heatmap configuration
HEATMAP_LEVELS = {
    1: "🟢",  # 1 problem
    2: "🟡",  # 2 problems  
    3: "🟠",  # 3 problems
    4: "🔴",  # 4+ problems
}
HEATMAP_EMPTY = "⚫"
HEATMAP_DAYS = 30

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

def ensure_directories() -> None:
    """Ensure necessary directories exist."""
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(CACHE_DIR, exist_ok=True)

def graphql_request(query: str, retries: int = 3, delay: float = 1) -> Dict:
    """
    Make a GraphQL request to LeetCode API with exponential backoff retry logic.
    
    Args:
        query: GraphQL query string
        retries: Number of retry attempts
        delay: Base delay between retries
    
    Returns:
        JSON response from API
        
    Raises:
        requests.RequestException: If all retries fail
    """
    for attempt in range(retries):
        try:
            response = requests.post(LEETCODE_URL, json={"query": query})
            response.raise_for_status()
            return response.json()
        except requests.RequestException as e:
            if attempt < retries - 1:
                time.sleep(delay * (2 ** attempt))  # exponential backoff
                continue
            else:
                raise e

def parse_date_arg(args: List[str]) -> date:
    """
    Parse date arguments from command line.
    
    Args:
        args: Command line arguments
        
    Returns:
        Parsed date object
    """
    if "--today" in args:
        return date.today()
    if "--yesterday" in args:
        return date.today() - timedelta(days=1)

    # Support -d YYYY-MM-DD or --date=YYYY-MM-DD
    if "-d" in args:
        idx = args.index("-d")
        if idx + 1 < len(args):
            return datetime.strptime(args[idx + 1], "%Y-%m-%d").date()

    for arg in args:
        if arg.startswith("--date="):
            return datetime.strptime(arg.split("=", 1)[1], "%Y-%m-%d").date()

    return date.today()  # default to today

def load_json_file(filepath: str, default: Any = None) -> Any:
    """Load JSON data from file, return default if file doesn't exist."""
    if os.path.exists(filepath):
        with open(filepath, "r") as f:
            return json.load(f)
    return default if default is not None else {}

def save_json_file(filepath: str, data: Any) -> None:
    """Save data as JSON to file."""
    with open(filepath, "w") as f:
        json.dump(data, f, indent=2)

# =============================================================================
# CACHE MANAGEMENT
# =============================================================================

def load_all_problems_cache() -> Optional[Dict]:
    """Load cached problems if they're from today."""
    data = load_json_file(ALL_PROBLEMS_CACHE, {})
    if data.get("date") == date.today().isoformat():
        return data.get("problems", {})
    return None

def save_all_problems_cache(problems: List[Dict]) -> None:
    """Save problems to cache with today's date."""
    save_json_file(ALL_PROBLEMS_CACHE, {
        "date": date.today().isoformat(),
        "problems": {str(p["frontendQuestionId"]): p for p in problems}
    })

def load_daily_cache(seed_date: date) -> Optional[Dict]:
    """Load cached daily problems for specific date."""
    data = load_json_file(CACHE_FILE, {})
    if data.get("date") == seed_date.isoformat():
        return data.get("problems")
    return None

def save_daily_cache(problems: Dict, seed_date: date) -> None:
    """Save daily problems to cache with date."""
    save_json_file(CACHE_FILE, {
        "date": seed_date.isoformat(), 
        "problems": problems
    })

def find_problem_by_id(problem_id: str, search_sources: List[Dict]) -> Optional[Dict]:
    """
    Find problem by ID in multiple search sources.
    
    Args:
        problem_id: Problem ID to search for
        search_sources: List of dictionaries to search in
        
    Returns:
        Problem data if found, None otherwise
    """
    for source in search_sources:
        if not source:
            continue
        problem = source.get(str(problem_id))
        if problem:
            return problem
    return None

# =============================================================================
# PROBLEM DATA MANAGEMENT
# =============================================================================

def fetch_all_problems(force_refresh: bool = False) -> Dict:
    """
    Fetch all problems from LeetCode API or cache.
    
    Args:
        force_refresh: Whether to ignore cache and fetch fresh data
        
    Returns:
        Dictionary of problems keyed by ID
    """
    if not force_refresh:
        cached = load_all_problems_cache()
        if cached:
            return cached

    try:
        response = graphql_request(ALL_PROBLEMS_QUERY)
        all_problems = response["data"]["problemsetQuestionList"]["questions"]
        save_all_problems_cache(all_problems)
        return {str(p["frontendQuestionId"]): p for p in all_problems}
    except Exception as e:
        print(f"❌ Error fetching all problems: {e}")
        return {}

def get_random_unsolved_problems(seed_date: date) -> Dict[str, Optional[Dict]]:
    """
    Get random unsolved problems for a specific date.
    
    Args:
        seed_date: Date to use as random seed
        
    Returns:
        Dictionary with easy, medium, hard problems
    """
    # Try cache first
    cached = load_daily_cache(seed_date)
    if cached:
        return cached

    try:
        # Set random seed based on date for consistent daily problems
        seed = int(seed_date.strftime("%Y%m%d"))
        random.seed(seed)

        # Fetch problems and filter
        all_problems = fetch_all_problems()
        solved_ids = {str(p["id"]) for p in load_solved()}
        
        free_problems = [
            p for p in all_problems.values() 
            if not p.get("paidOnly") and str(p["frontendQuestionId"]) not in solved_ids
        ]

        # Categorize by difficulty
        problems_by_diff = {
            "easy": [p for p in free_problems if p["difficulty"] == "Easy"],
            "medium": [p for p in free_problems if p["difficulty"] == "Medium"],
            "hard": [p for p in free_problems if p["difficulty"] == "Hard"],
        }

        # Select random problems
        result = {
            diff: random.choice(problems) if problems else None
            for diff, problems in problems_by_diff.items()
        }

        save_daily_cache(result, seed_date)
        return result

    except Exception as e:
        print(f"❌ Error fetching problems: {e}")
        return {}

def load_solved() -> List[Dict]:
    """Load list of solved problems."""
    return load_json_file(SOLVED_FILE, [])

def save_solved(solved: List[Dict]) -> None:
    """Save solved problems list."""
    save_json_file(SOLVED_FILE, solved)

# =============================================================================
# DISPLAY FUNCTIONS
# =============================================================================

def display_problems(problems: Dict) -> None:
    """Display problems in a formatted way."""
    if not problems:
        print("❌ Failed to fetch problems.")
        return

    solved_ids = {p["id"] for p in load_solved()}
    
    print("\n🎯 Your Daily LeetCode Challenge (Random Unsolved):\n")

    for difficulty in DIFFICULTIES:
        problem = problems.get(difficulty)
        icon = DIFFICULTY_ICONS.get(difficulty, "❓")
        
        if problem:
            solved_marker = " ✅" if str(problem["frontendQuestionId"]) in solved_ids else ""
            print(f"{icon} {difficulty.upper()}:")
            print(f"   ID: {problem['frontendQuestionId']}{solved_marker}")
            print(f"   Title: {problem['title']}")
            print(f"   Acceptance: {problem['acRate']:.1f}%")
            print(f"   Link: https://leetcode.com/problems/{problem['titleSlug']}/\n")
        else:
            print(f"❌ No {difficulty} problem available today.")

def display_solved_problems() -> None:
    """Display all solved problems."""
    solved = sorted(load_solved(), key=lambda p: int(p["id"]))
    
    if not solved:
        print("📂 No problems solved yet.")
        return

    print("\n📂 Solved Problems:\n")
    
    for problem in solved:
        icon = DIFFICULTY_COLORS.get(problem["difficulty"], "❓")
        print(f"{icon} [{problem['id']}] {problem['title']} ({problem['difficulty']})")
        print(f"   🔗 https://leetcode.com/problems/{problem['slug']}/\n")

# =============================================================================
# PROFILE AND STATISTICS
# =============================================================================

def calculate_streaks(solved_problems: List[Dict]) -> tuple[int, int]:
    """
    Calculate current and longest streaks from solved problems.
    
    Args:
        solved_problems: List of solved problem records
        
    Returns:
        Tuple of (current_streak, longest_streak)
    """
    if not solved_problems:
        return 0, 0

    # Get unique solved dates
    dates = sorted({
        datetime.fromisoformat(p["completed_at"]).date() 
        for p in solved_problems
    })
    
    # Calculate longest streak
    longest_streak = 1
    current_streak = 1
    
    for i in range(1, len(dates)):
        if (dates[i] - dates[i-1]).days == 1:
            current_streak += 1
            longest_streak = max(longest_streak, current_streak)
        else:
            current_streak = 1

    # Calculate current streak (consecutive days up to today)
    current_streak = 0
    day_check = date.today()
    solved_dates_set = set(dates)
    
    while day_check in solved_dates_set:
        current_streak += 1
        day_check -= timedelta(days=1)

    return current_streak, max(longest_streak, 1)

def generate_heatmap(solved_problems: List[Dict], days: int = HEATMAP_DAYS) -> str:
    """
    Generate heatmap string for recent activity.
    
    Args:
        solved_problems: List of solved problems
        days: Number of days to include in heatmap
        
    Returns:
        Heatmap as string of emojis
    """
    if not solved_problems:
        return HEATMAP_EMPTY * days
    
    today = date.today()
    date_range = [today - timedelta(days=i) for i in range(days-1, -1, -1)]
    
    # Count problems solved per day
    daily_counts = {}
    for problem in solved_problems:
        problem_date = datetime.fromisoformat(problem["completed_at"]).date()
        if problem_date in date_range:
            daily_counts[problem_date] = daily_counts.get(problem_date, 0) + 1
    
    # Generate heatmap characters
    heatmap_chars = []
    for day_date in date_range:
        count = daily_counts.get(day_date, 0)
        if count == 0:
            heatmap_chars.append(HEATMAP_EMPTY)
        else:
            # Use appropriate emoji based on problem count
            for threshold, emoji in sorted(HEATMAP_LEVELS.items(), reverse=True):
                if count >= threshold:
                    heatmap_chars.append(emoji)
                    break
            else:
                heatmap_chars.append(HEATMAP_LEVELS[1])
    
    return "".join(heatmap_chars)

def calculate_statistics(solved_problems: List[Dict]) -> Dict[str, Any]:
    """
    Calculate comprehensive statistics from solved problems.
    
    Args:
        solved_problems: List of solved problem records
        
    Returns:
        Dictionary containing various statistics
    """
    if not solved_problems:
        return {
            "total_solved": 0,
            "by_difficulty": {"Easy": 0, "Medium": 0, "Hard": 0},
            "current_streak": 0,
            "longest_streak": 0,
            "heatmap": generate_heatmap([])
        }
    
    total = len(solved_problems)
    by_difficulty = {"Easy": 0, "Medium": 0, "Hard": 0}
    
    for problem in solved_problems:
        by_difficulty[problem["difficulty"]] += 1
    
    current_streak, longest_streak = calculate_streaks(solved_problems)
    heatmap = generate_heatmap(solved_problems)
    
    return {
        "total_solved": total,
        "by_difficulty": by_difficulty,
        "current_streak": current_streak,
        "longest_streak": longest_streak,
        "heatmap": heatmap
    }

def display_weekly_report() -> None:
    """Display weekly activity report."""
    solved = load_solved()
    cutoff = datetime.utcnow() - timedelta(days=7)
    recent = [p for p in solved if datetime.fromisoformat(p["completed_at"]) >= cutoff]
    
    stats = calculate_statistics(recent)
    
    print("\n📊 Weekly Report (last 7 days):\n")
    print(f"Total solved: {stats['total_solved']}")
    print(f"  🟢 Easy:   {stats['by_difficulty']['Easy']}")
    print(f"  🟡 Medium: {stats['by_difficulty']['Medium']}")
    print(f"  🔴 Hard:   {stats['by_difficulty']['Hard']}\n")
    
    if recent:
        print("Recent solves:")
        for problem in sorted(recent, key=lambda x: x["completed_at"], reverse=True):
            time_str = datetime.fromisoformat(problem["completed_at"]).strftime("%Y-%m-%d")
            print(f"  [{problem['id']}] {problem['title']} ({problem['difficulty']}) — {time_str}")

def display_profile() -> None:
    """Display comprehensive profile with statistics."""
    # Update goal progress first
    update_goal_progress()
    
    solved = load_solved()
    stats = calculate_statistics(solved)
    
    # Save profile data
    save_json_file(PROFILE_FILE, stats)
    
    # Display statistics
    print("\n📈 Overall Stats:\n")
    print(f"Total solved: {stats['total_solved']}")
    print(f"🟢 Easy:   {stats['by_difficulty']['Easy']}")
    print(f"🟡 Medium: {stats['by_difficulty']['Medium']}")
    print(f"🔴 Hard:   {stats['by_difficulty']['Hard']}\n")
    print(f"🔥 Current streak: {stats['current_streak']} days")
    print(f"🏆 Longest streak: {stats['longest_streak']} days\n")
    
    # Progress bars
    max_val = max(stats['by_difficulty'].values()) or 1
    for difficulty, icon in DIFFICULTY_COLORS.items():
        count = stats['by_difficulty'][difficulty]
        bar_length = int((count / max_val) * 20)
        bar = "█" * bar_length
        print(f"{icon} {difficulty:<6} {bar} {count}")

    # Show goal progress
    goals = load_goals()
    active_goals = [g for g in goals if g["status"] == GoalStatus.ACTIVE]
    if active_goals:
        print("\n🎯 ACTIVE GOALS:")
        for goal in active_goals[:3]:  # Show first 3 active goals
            progress = (goal["current"] / goal["target"]) * 100
            print(f"   {goal['name']}: {goal['current']}/{goal['target']} ({progress:.1f}%)")
    
    # Heatmap display (grouped by weeks)
    heatmap_chars = list(stats['heatmap'])
    heatmap_display = []
    for i in range(0, len(heatmap_chars), 7):
        heatmap_display.append(" ".join(heatmap_chars[i:i+7]))
    
    print("\n📅 Last 30 days heatmap:\n")
    for week in heatmap_display:
        print(week)
    print("\n🟩 = 1 solved, 🟡 = 2, 🟠 = 3, 🔴 = 4+, ⬛ = none\n")

# =============================================================================
# PROBLEM STATUS MANAGEMENT
# =============================================================================

def mark_problem_status(problem_id: str, mark_as_solved: bool, force_refresh: bool = False) -> None:
    """
    Mark a problem as solved or incomplete.
    
    Args:
        problem_id: ID of the problem to update
        mark_as_solved: True to mark as solved, False to mark as incomplete
        force_refresh: Whether to refresh problem cache
    """
    solved = load_solved()
    problem_id_str = str(problem_id)
    
    # Check if problem is already in desired state
    is_currently_solved = any(str(p["id"]) == problem_id_str for p in solved)
    
    if mark_as_solved and is_currently_solved:
        print(f"⚠️ Problem {problem_id} is already marked as solved.")
        return
    elif not mark_as_solved and not is_currently_solved:
        print(f"⚠️ Problem {problem_id} was not marked as solved.")
        return
    
    if mark_as_solved:
        # Find problem details
        all_problems = fetch_all_problems(force_refresh) if force_refresh else fetch_all_problems()
        daily_cache = load_daily_cache(date.today())
        
        problem = find_problem_by_id(problem_id, [all_problems, daily_cache])
        
        if not problem:
            print(f"❌ Problem {problem_id} not found.")
            return
        
        # Add to solved list
        solved.append({
            "id": problem["frontendQuestionId"],
            "title": problem["title"],
            "slug": problem["titleSlug"],
            "difficulty": problem["difficulty"],
            "completed_at": datetime.utcnow().isoformat()
        })
        save_solved(solved)
        print(f"✅ Problem {problem_id} ({problem['title']}) marked as solved.")
        
    else:
        # Remove from solved list
        solved = [p for p in solved if str(p["id"]) != problem_id_str]
        save_solved(solved)
        print(f"↩️ Problem {problem_id} marked as incomplete.")
    
    # Update profile after status change
    if mark_as_solved or (not mark_as_solved and is_currently_solved):
        stats = calculate_statistics(load_solved())
        save_json_file(PROFILE_FILE, stats)

# =============================================================================
# GOAL MANAGEMENT
# =============================================================================

def load_goals() -> List[Dict]:
    """Load goals from file."""
    return load_json_file(GOALS_FILE, [])

def save_goals(goals: List[Dict]) -> None:
    """Save goals to file."""
    save_json_file(GOALS_FILE, goals)

def create_goal(name: str, goal_type: str, target: int, difficulty: str = None, deadline_days: int = 30) -> None:
    """Create a new goal."""
    goals = load_goals()
    
    goal = {
        "id": len(goals) + 1,
        "name": name,
        "type": goal_type,
        "target": target,
        "current": 0,
        "difficulty": difficulty,
        "created_date": date.today().isoformat(),
        "deadline": (date.today() + timedelta(days=deadline_days)).isoformat(),
        "status": GoalStatus.ACTIVE
    }
    
    goals.append(goal)
    save_goals(goals)
    print(f"✅ Goal '{name}' created! (ID: {goal['id']})")

def update_goal_progress() -> None:
    """Update progress for all active goals based on current stats."""
    goals = load_goals()
    if not goals:
        return
        
    stats = calculate_statistics(load_solved())
    solved = load_solved()
    
    # Get recent solves (last 7 days for weekly targets)
    week_ago = datetime.utcnow() - timedelta(days=7)
    recent_solves = [p for p in solved if datetime.fromisoformat(p["completed_at"]) >= week_ago]
    
    for goal in goals:
        if goal["status"] != GoalStatus.ACTIVE:
            continue
            
        if goal["type"] == GoalType.TOTAL_SOLVED:
            goal["current"] = stats["total_solved"]
        elif goal["type"] == GoalType.DAILY_STREAK:
            goal["current"] = stats["current_streak"]
        elif goal["type"] == GoalType.DIFFICULTY_COUNT and goal["difficulty"]:
            goal["current"] = stats["by_difficulty"][goal["difficulty"]]
        elif goal["type"] == GoalType.WEEKLY_TARGET:
            goal["current"] = len(recent_solves)
        
        # Check if goal is completed
        if goal["current"] >= goal["target"]:
            goal["status"] = GoalStatus.COMPLETED
            goal["completed_date"] = date.today().isoformat()
        # Check if goal is failed (past deadline)
        elif date.fromisoformat(goal["deadline"]) < date.today():
            goal["status"] = GoalStatus.FAILED
    
    save_goals(goals)

def display_goals() -> None:
    """Display all goals with progress."""
    update_goal_progress()  # Refresh progress first
    goals = load_goals()
    
    if not goals:
        print("🎯 No goals set yet. Use 'leetcode create-goal' to get started!")
        return
    
    active_goals = [g for g in goals if g["status"] == GoalStatus.ACTIVE]
    completed_goals = [g for g in goals if g["status"] == GoalStatus.COMPLETED]
    
    print("\n🎯 YOUR GOALS\n")
    
    if active_goals:
        print("📈 ACTIVE GOALS:")
        for goal in active_goals:
            progress = (goal["current"] / goal["target"]) * 100
            bar = "█" * int(progress / 5) + "░" * (20 - int(progress / 5))
            deadline = date.fromisoformat(goal["deadline"])
            days_left = (deadline - date.today()).days
            
            print(f"   {goal['id']}. {goal['name']}")
            print(f"      {bar} {goal['current']}/{goal['target']} ({progress:.1f}%)")
            print(f"      📅 Deadline: {deadline} ({days_left} days left)")
            if goal["difficulty"]:
                print(f"      🎯 Difficulty: {goal['difficulty']}")
            print()
    
    if completed_goals:
        print("✅ COMPLETED GOALS:")
        for goal in completed_goals:
            completed_date = goal.get("completed_date", goal["deadline"])
            print(f"   {goal['id']}. {goal['name']} - Completed on {completed_date}")
        print()

def quick_start_goals() -> None:
    """Create some default goals for new users."""
    goals = load_goals()
    if goals:
        return
        
    default_goals = [
        {"name": "First Steps", "type": GoalType.TOTAL_SOLVED, "target": 5, "difficulty": None, "deadline_days": 14},
        {"name": "Weekly Warrior", "type": GoalType.WEEKLY_TARGET, "target": 3, "difficulty": None, "deadline_days": 7},
        {"name": "Streak Builder", "type": GoalType.DAILY_STREAK, "target": 3, "difficulty": None, "deadline_days": 10},
    ]
    
    for goal_data in default_goals:
        create_goal(**goal_data)
    
    print("🎯 Created starter goals! Use 'leetcode goals' to view them.")

# =============================================================================
# COMMAND LINE INTERFACE
# =============================================================================

def print_help() -> None:
    """Display help message."""
    print("""
leetcode - Your Daily LeetCode CLI 🎯

Usage:
  leetcode fetch [options]           Fetch daily random problems
  leetcode markAsDone [id]           Mark problem as solved
  leetcode markAsIncomplete [id]     Unmark problem as solved
  leetcode listSolved                Show all solved problems
  leetcode report                    Show weekly activity report
  leetcode get profile               Show overall stats, streaks and goals
  leetcode stats                     Alias for 'get profile'
  leetcode goals                     View your goals and progress
  leetcode create-goal [args]        Create a new goal
  leetcode quick-goals               Create starter goals for beginners

Options for 'fetch':
  -d YYYY-MM-DD      Fetch for a specific date
  --date=YYYY-MM-DD  Same as -d
  --today            Fetch today's problems (default)
  --yesterday        Fetch yesterday's problems
  --refresh-cache    Force refresh problem cache

Other:
  -h, --help         Show this help message
""")

def main() -> None:
    """Main command line interface handler."""
    ensure_directories()
    
    if len(sys.argv) < 2:
        print_help()
        sys.exit(1)

    command = sys.argv[1]

    # Quick start goals for new users
    if not os.path.exists(GOALS_FILE):
        quick_start_goals()

    if command in ("-h", "--help"):
        print_help()
    
    elif command == "goals":
        display_goals()
    
    elif command == "create-goal" and len(sys.argv) >= 5:
        # leetcode create-goal "Goal Name" total_solved 10
        name = sys.argv[2]
        goal_type = sys.argv[3]
        target = int(sys.argv[4])
        difficulty = sys.argv[5] if len(sys.argv) > 5 else None
        create_goal(name, goal_type, target, difficulty)
    
    elif command == "quick-goals":
        quick_start_goals()

    elif command == "fetch":
        seed_date = parse_date_arg(sys.argv[2:])
        force_refresh = "--refresh-cache" in sys.argv[2:]
        
        if force_refresh:
            print("🔄 Refreshing problems cache...")
            fetch_all_problems(force_refresh=True)
        
        print(f"Fetching LeetCode problems for {seed_date.isoformat()}...")
        problems = get_random_unsolved_problems(seed_date)
        display_problems(problems)
    
    elif command == "markAsDone" and len(sys.argv) >= 3:
        force_refresh = "--refresh-cache" in sys.argv
        mark_problem_status(sys.argv[2], mark_as_solved=True, force_refresh=force_refresh)
    
    elif command == "markAsIncomplete" and len(sys.argv) == 3:
        mark_problem_status(sys.argv[2], mark_as_solved=False)
    
    elif command == "listSolved":
        display_solved_problems()
    
    elif command == "report":
        display_weekly_report()
    
    elif command in ("stats", "get"):
        if command == "get" and len(sys.argv) > 2 and sys.argv[2] == "profile":
            display_profile()
        elif command == "stats" or (command == "get" and len(sys.argv) == 2):
            display_profile()
        else:
            print("⚠️ Usage: leetcode get profile")
    
    else:
        print("❌ Invalid command or arguments.")
        print_help()
        sys.exit(1)

if __name__ == "__main__":
    main()