#!/usr/bin/env python3
"""
LeetCode Tracker CLI - Production Ready

A streamlined CLI tool for tracking LeetCode progress with goals, statistics,
and daily problem recommendations.
"""

import asyncio
import aiohttp
import random
import json
import os
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Any, Tuple
from dataclasses import dataclass, asdict
from enum import Enum
import hashlib

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================

class GoalType(str, Enum):
    TOTAL_SOLVED = "total_solved"
    DAILY_STREAK = "daily_streak" 
    DIFFICULTY_COUNT = "difficulty_count"
    WEEKLY_TARGET = "weekly_target"

class GoalStatus(str, Enum):
    ACTIVE = "active"
    COMPLETED = "completed"
    FAILED = "failed"

class Difficulty(str, Enum):
    EASY = "Easy"
    MEDIUM = "Medium"
    HARD = "Hard"

# Path configuration
BASE_DIR = Path.home() / ".local" / "share" / "leetcode_tracker"
CACHE_DIR = Path.home() / ".cache" / "leetcode_tracker"

# File paths
SOLVED_FILE = BASE_DIR / "solved.json"
CACHE_FILE = CACHE_DIR / "daily.json"
ALL_PROBLEMS_CACHE = CACHE_DIR / "all_problems.json"
PROFILE_FILE = BASE_DIR / "profile.json"
GOALS_FILE = BASE_DIR / "goals.json"

# API configuration
LEETCODE_URL = "https://leetcode.com/graphql"
REQUEST_TIMEOUT = 10
MAX_RETRIES = 3

# Display configuration
DIFFICULTY_ICONS = {
    Difficulty.EASY: "🟢",
    Difficulty.MEDIUM: "🟡", 
    Difficulty.HARD: "🔴"
}

HEATMAP_LEVELS = {
    0: "⚫",  # 0 problems
    1: "🟢",  # 1 problem
    2: "🟡",  # 2 problems  
    3: "🟠",  # 3 problems
    4: "🔴",  # 4+ problems
}

# =============================================================================
# DATA MODELS
# =============================================================================

@dataclass
class Problem:
    """Represents a LeetCode problem."""
    id: str
    title: str
    slug: str
    difficulty: Difficulty
    ac_rate: float
    paid_only: bool = False
    
    @property
    def url(self) -> str:
        return f"https://leetcode.com/problems/{self.slug}/"

@dataclass
class SolvedProblem:
    """Represents a solved problem with completion metadata."""
    problem_id: str
    title: str
    slug: str
    difficulty: Difficulty
    completed_at: str
    
    @classmethod
    def from_problem(cls, problem: Problem) -> 'SolvedProblem':
        return cls(
            problem_id=problem.id,
            title=problem.title,
            slug=problem.slug,
            difficulty=problem.difficulty,
            completed_at=datetime.utcnow().isoformat()
        )

@dataclass
class Goal:
    """Represents a user goal."""
    id: int
    name: str
    type: GoalType
    target: int
    current: int = 0
    difficulty: Optional[Difficulty] = None
    created_date: str = None
    deadline: str = None
    status: GoalStatus = GoalStatus.ACTIVE
    
    def __post_init__(self):
        if self.created_date is None:
            self.created_date = date.today().isoformat()
        if self.deadline is None:
            self.deadline = (date.today() + timedelta(days=30)).isoformat()
    
    @property
    def progress_percentage(self) -> float:
        return (self.current / self.target) * 100 if self.target > 0 else 0
    
    @property
    def days_remaining(self) -> int:
        return (date.fromisoformat(self.deadline) - date.today()).days

@dataclass
class UserStats:
    """Represents user statistics."""
    total_solved: int = 0
    by_difficulty: Dict[Difficulty, int] = None
    current_streak: int = 0
    longest_streak: int = 0
    heatmap: str = ""
    
    def __post_init__(self):
        if self.by_difficulty is None:
            self.by_difficulty = {diff: 0 for diff in Difficulty}

# =============================================================================
# CORE SERVICES
# =============================================================================

class CacheService:
    """Handles data caching with TTL support."""
    
    @staticmethod
    def ensure_directories() -> None:
        """Ensure necessary directories exist."""
        BASE_DIR.mkdir(parents=True, exist_ok=True)
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
    
    @staticmethod
    def load_json(filepath: Path, default: Any = None) -> Any:
        """Load JSON data from file with error handling."""
        try:
            if filepath.exists():
                return json.loads(filepath.read_text())
        except (json.JSONDecodeError, IOError) as e:
            print(f"⚠️ Warning: Could not load {filepath}: {e}")
        return default if default is not None else {}
    
    @staticmethod
    def save_json(filepath: Path, data: Any) -> bool:
        """Save data as JSON to file with error handling."""
        try:
            filepath.parent.mkdir(parents=True, exist_ok=True)
            filepath.write_text(json.dumps(data, indent=2))
            return True
        except IOError as e:
            print(f"❌ Error saving to {filepath}: {e}")
            return False
    
    @staticmethod
    def is_cache_valid(filepath: Path, ttl_days: int = 1) -> bool:
        """Check if cache file is still valid."""
        if not filepath.exists():
            return False
        
        cache_date = datetime.fromtimestamp(filepath.stat().st_mtime).date()
        return (date.today() - cache_date).days < ttl_days

class LeetCodeAPI:
    """Handles communication with LeetCode GraphQL API."""
    
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
    
    def __init__(self):
        self.session = None
    
    async def __aenter__(self):
        self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=REQUEST_TIMEOUT))
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        if self.session:
            await self.session.close()
    
    async def fetch_all_problems(self) -> Dict[str, Problem]:
        """Fetch all problems from LeetCode API."""
        for attempt in range(MAX_RETRIES):
            try:
                async with self.session.post(
                    LEETCODE_URL, 
                    json={"query": self.ALL_PROBLEMS_QUERY},
                    headers={"Content-Type": "application/json"}
                ) as response:
                    response.raise_for_status()
                    data = await response.json()
                    
                    problems = {}
                    for item in data["data"]["problemsetQuestionList"]["questions"]:
                        problem = Problem(
                            id=str(item["frontendQuestionId"]),
                            title=item["title"],
                            slug=item["titleSlug"],
                            difficulty=Difficulty(item["difficulty"]),
                            ac_rate=float(item["acRate"]),
                            paid_only=bool(item["paidOnly"])
                        )
                        problems[problem.id] = problem
                    
                    return problems
                    
            except (aiohttp.ClientError, KeyError, ValueError) as e:
                if attempt == MAX_RETRIES - 1:
                    raise e
                await asyncio.sleep(2 ** attempt)  # Exponential backoff
        
        return {}

class ProblemService:
    """Manages problem data and recommendations."""
    
    def __init__(self, cache_service: CacheService):
        self.cache = cache_service
    
    async def get_all_problems(self, force_refresh: bool = False) -> Dict[str, Problem]:
        """Get all problems, using cache when possible."""
        if not force_refresh and self.cache.is_cache_valid(ALL_PROBLEMS_CACHE):
            cached = self.cache.load_json(ALL_PROBLEMS_CACHE, {})
            return {pid: Problem(**data) for pid, data in cached.items()}
        
        try:
            async with LeetCodeAPI() as api:
                problems = await api.fetch_all_problems()
                
                # Cache the problems
                cache_data = {pid: asdict(problem) for pid, problem in problems.items()}
                self.cache.save_json(ALL_PROBLEMS_CACHE, cache_data)
                
                return problems
        except Exception as e:
            print(f"❌ Error fetching problems: {e}")
            # Fallback to cache even if stale
            cached = self.cache.load_json(ALL_PROBLEMS_CACHE, {})
            return {pid: Problem(**data) for pid, data in cached.items()}
    
    def get_daily_problems(self, seed_date: date) -> Dict[Difficulty, Optional[Problem]]:
        """Get random unsolved problems for a specific date."""
        # Try cache first
        cache_key = f"{seed_date.isoformat()}_problems"
        cached_data = self.cache.load_json(CACHE_FILE, {})
        
        if cache_key in cached_data:
            cached_problems = cached_data[cache_key]
            return {
                Difficulty(diff): Problem(**data) if data else None
                for diff, data in cached_problems.items()
            }
        
        # Will be populated by async method
        return {diff: None for diff in Difficulty}
    
    async def generate_daily_problems(self, seed_date: date) -> Dict[Difficulty, Optional[Problem]]:
        """Generate and cache random unsolved problems for a date."""
        all_problems = await self.get_all_problems()
        solved_ids = {sp.problem_id for sp in self.get_solved_problems()}
        
        # Filter free, unsolved problems
        free_unsolved = [
            problem for problem in all_problems.values()
            if not problem.paid_only and problem.id not in solved_ids
        ]
        
        # Group by difficulty
        problems_by_diff = {
            difficulty: [p for p in free_unsolved if p.difficulty == difficulty]
            for difficulty in Difficulty
        }
        
        # Set seed for consistent daily problems
        seed = int(seed_date.strftime("%Y%m%d"))
        random.seed(seed)
        
        # Select random problems
        daily_problems = {
            diff: random.choice(problems) if problems else None
            for diff, problems in problems_by_diff.items()
        }
        
        # Cache results
        cache_data = self.cache.load_json(CACHE_FILE, {})
        cache_key = f"{seed_date.isoformat()}_problems"
        cache_data[cache_key] = {
            diff.value: asdict(problem) if problem else None
            for diff, problem in daily_problems.items()
        }
        self.cache.save_json(CACHE_FILE, cache_data)
        
        return daily_problems
    
    def get_solved_problems(self) -> List[SolvedProblem]:
        """Load solved problems from storage."""
        data = self.cache.load_json(SOLVED_FILE, [])
        return [SolvedProblem(**item) for item in data]
    
    def save_solved_problems(self, solved: List[SolvedProblem]) -> bool:
        """Save solved problems to storage."""
        return self.cache.save_json(SOLVED_FILE, [asdict(sp) for sp in solved])
    
    def mark_problem_solved(self, problem_id: str, problem: Problem) -> bool:
        """Mark a problem as solved."""
        solved = self.get_solved_problems()
        
        # Check if already solved
        if any(sp.problem_id == problem_id for sp in solved):
            return False
        
        solved_problem = SolvedProblem.from_problem(problem)
        solved.append(solved_problem)
        
        return self.save_solved_problems(solved)
    
    def mark_problem_unsolved(self, problem_id: str) -> bool:
        """Mark a problem as unsolved."""
        solved = self.get_solved_problems()
        original_count = len(solved)
        
        solved = [sp for sp in solved if sp.problem_id != problem_id]
        
        if len(solved) == original_count:
            return False  # Problem wasn't solved
        
        return self.save_solved_problems(solved)

class StatsService:
    """Calculates and manages user statistics."""
    
    def __init__(self, problem_service: ProblemService):
        self.problem_service = problem_service
    
    def calculate_stats(self, solved_problems: List[SolvedProblem]) -> UserStats:
        """Calculate comprehensive user statistics."""
        if not solved_problems:
            return UserStats(heatmap=self._generate_heatmap([]))
        
        # Basic counts
        by_difficulty = {diff: 0 for diff in Difficulty}
        for problem in solved_problems:
            by_difficulty[problem.difficulty] += 1
        
        total_solved = len(solved_problems)
        current_streak, longest_streak = self._calculate_streaks(solved_problems)
        heatmap = self._generate_heatmap(solved_problems)
        
        return UserStats(
            total_solved=total_solved,
            by_difficulty=by_difficulty,
            current_streak=current_streak,
            longest_streak=longest_streak,
            heatmap=heatmap
        )
    
    def _calculate_streaks(self, solved_problems: List[SolvedProblem]) -> Tuple[int, int]:
        """Calculate current and longest streaks."""
        if not solved_problems:
            return 0, 0
        
        # Get unique solved dates
        dates = sorted({
            datetime.fromisoformat(p.completed_at).date() 
            for p in solved_problems
        })
        
        # Calculate streaks
        current_streak = 0
        longest_streak = 1
        temp_streak = 1
        
        for i in range(1, len(dates)):
            if (dates[i] - dates[i-1]).days == 1:
                temp_streak += 1
                longest_streak = max(longest_streak, temp_streak)
            else:
                temp_streak = 1
        
        # Calculate current streak (consecutive days up to today)
        check_date = date.today()
        while check_date in set(dates):
            current_streak += 1
            check_date -= timedelta(days=1)
        
        return current_streak, max(longest_streak, 1)
    
    def _generate_heatmap(self, solved_problems: List[SolvedProblem], days: int = 30) -> str:
        """Generate activity heatmap for recent days."""
        if not solved_problems:
            return HEATMAP_LEVELS[0] * days
        
        today = date.today()
        date_range = [today - timedelta(days=i) for i in range(days-1, -1, -1)]
        
        # Count problems solved per day
        daily_counts = {}
        for problem in solved_problems:
            problem_date = datetime.fromisoformat(problem.completed_at).date()
            if problem_date in date_range:
                daily_counts[problem_date] = daily_counts.get(problem_date, 0) + 1
        
        # Generate heatmap
        heatmap = []
        for day_date in date_range:
            count = daily_counts.get(day_date, 0)
            for threshold, emoji in sorted(HEATMAP_LEVELS.items(), reverse=True):
                if count >= threshold:
                    heatmap.append(emoji)
                    break
        
        return "".join(heatmap)

class GoalService:
    """Manages user goals and progress tracking."""
    
    def __init__(self, cache_service: CacheService, stats_service: StatsService):
        self.cache = cache_service
        self.stats = stats_service
    
    def get_goals(self) -> List[Goal]:
        """Load goals from storage."""
        data = self.cache.load_json(GOALS_FILE, [])
        return [Goal(**item) for item in data]
    
    def save_goals(self, goals: List[Goal]) -> bool:
        """Save goals to storage."""
        return self.cache.save_json(GOALS_FILE, [asdict(goal) for goal in goals])
    
    def create_goal(self, name: str, goal_type: GoalType, target: int, 
                   difficulty: Optional[Difficulty] = None, deadline_days: int = 30) -> Optional[Goal]:
        """Create a new goal."""
        goals = self.get_goals()
        goal_id = max([g.id for g in goals], default=0) + 1
        
        goal = Goal(
            id=goal_id,
            name=name,
            type=goal_type,
            target=target,
            difficulty=difficulty,
            deadline=(date.today() + timedelta(days=deadline_days)).isoformat()
        )
        
        goals.append(goal)
        if self.save_goals(goals):
            return goal
        return None
    
    def update_goal_progress(self) -> bool:
        """Update progress for all active goals."""
        goals = self.get_goals()
        if not goals:
            return True
        
        stats = self.stats.calculate_stats(self.stats.problem_service.get_solved_problems())
        solved_problems = self.stats.problem_service.get_solved_problems()
        
        # Get recent solves for weekly targets
        week_ago = datetime.utcnow() - timedelta(days=7)
        recent_solves = [
            p for p in solved_problems 
            if datetime.fromisoformat(p.completed_at) >= week_ago
        ]
        
        for goal in goals:
            if goal.status != GoalStatus.ACTIVE:
                continue
            
            # Update progress based on goal type
            if goal.type == GoalType.TOTAL_SOLVED:
                goal.current = stats.total_solved
            elif goal.type == GoalType.DAILY_STREAK:
                goal.current = stats.current_streak
            elif goal.type == GoalType.DIFFICULTY_COUNT and goal.difficulty:
                goal.current = stats.by_difficulty[goal.difficulty]
            elif goal.type == GoalType.WEEKLY_TARGET:
                goal.current = len(recent_solves)
            
            # Check goal completion
            if goal.current >= goal.target:
                goal.status = GoalStatus.COMPLETED
            elif goal.days_remaining < 0:
                goal.status = GoalStatus.FAILED
        
        return self.save_goals(goals)
    
    def create_starter_goals(self) -> bool:
        """Create default goals for new users."""
        if self.get_goals():
            return False  # Already has goals
        
        starter_goals = [
            ("First Steps", GoalType.TOTAL_SOLVED, 5, None, 14),
            ("Weekly Warrior", GoalType.WEEKLY_TARGET, 3, None, 7),
            ("Streak Builder", GoalType.DAILY_STREAK, 3, None, 10),
        ]
        
        for name, goal_type, target, difficulty, days in starter_goals:
            self.create_goal(name, goal_type, target, difficulty, days)
        
        return True

# =============================================================================
# UI COMPONENTS
# =============================================================================

class DisplayService:
    """Handles all console output and formatting."""
    
    @staticmethod
    def print_header(text: str) -> None:
        """Print a formatted header."""
        print(f"\n🎯 {text}")
        print("=" * 50)
    
    @staticmethod
    def print_success(text: str) -> None:
        """Print success message."""
        print(f"✅ {text}")
    
    @staticmethod
    def print_error(text: str) -> None:
        """Print error message."""
        print(f"❌ {text}")
    
    @staticmethod
    def print_warning(text: str) -> None:
        """Print warning message."""
        print(f"⚠️ {text}")
    
    def display_problems(self, problems: Dict[Difficulty, Optional[Problem]], 
                        solved_ids: set) -> None:
        """Display problems in a formatted way."""
        self.print_header("Your Daily LeetCode Challenge")
        
        for difficulty in Difficulty:
            problem = problems.get(difficulty)
            icon = DIFFICULTY_ICONS.get(difficulty, "❓")
            
            if problem:
                solved_marker = " ✅" if problem.id in solved_ids else ""
                print(f"\n{icon} {difficulty.value.upper()}:{solved_marker}")
                print(f"   ID: {problem.id}")
                print(f"   Title: {problem.title}")
                print(f"   Acceptance: {problem.ac_rate:.1f}%")
                print(f"   Link: {problem.url}")
            else:
                print(f"\n❌ No {difficulty.value} problem available today.")
        
        print()
    
    def display_solved_problems(self, solved_problems: List[SolvedProblem]) -> None:
        """Display all solved problems."""
        if not solved_problems:
            self.print_warning("No problems solved yet.")
            return
        
        self.print_header("Solved Problems")
        
        for problem in sorted(solved_problems, key=lambda p: int(p.problem_id)):
            icon = DIFFICULTY_ICONS.get(problem.difficulty, "❓")
            date_str = datetime.fromisoformat(problem.completed_at).strftime("%Y-%m-%d")
            print(f"{icon} [{problem.problem_id}] {problem.title}")
            print(f"   Completed: {date_str}")
            print(f"   Link: https://leetcode.com/problems/{problem.slug}/")
            print()
    
    def display_stats(self, stats: UserStats) -> None:
        """Display user statistics."""
        self.print_header("Your LeetCode Stats")
        
        print(f"Total Solved: {stats.total_solved}")
        print(f"🟢 Easy:   {stats.by_difficulty[Difficulty.EASY]}")
        print(f"🟡 Medium: {stats.by_difficulty[Difficulty.MEDIUM]}")
        print(f"🔴 Hard:   {stats.by_difficulty[Difficulty.HARD]}")
        print(f"\n🔥 Current Streak: {stats.current_streak} days")
        print(f"🏆 Longest Streak: {stats.longest_streak} days")
        
        # Progress bars
        max_count = max(stats.by_difficulty.values()) or 1
        print("\nProgress:")
        for difficulty in Difficulty:
            count = stats.by_difficulty[difficulty]
            bar_length = int((count / max_count) * 20)
            bar = "█" * bar_length + "░" * (20 - bar_length)
            icon = DIFFICULTY_ICONS[difficulty]
            print(f"{icon} {difficulty.value:<6} {bar} {count}")
    
    def display_goals(self, goals: List[Goal]) -> None:
        """Display goals with progress."""
        active_goals = [g for g in goals if g.status == GoalStatus.ACTIVE]
        completed_goals = [g for g in goals if g.status == GoalStatus.COMPLETED]
        failed_goals = [g for g in goals if g.status == GoalStatus.FAILED]
        
        if active_goals:
            self.print_header("Active Goals")
            for goal in active_goals:
                bar_length = int((goal.progress_percentage / 100) * 20)
                bar = "█" * bar_length + "░" * (20 - bar_length)
                
                print(f"\n{goal.id}. {goal.name}")
                print(f"   {bar} {goal.current}/{goal.target} ({goal.progress_percentage:.1f}%)")
                print(f"   📅 {goal.days_remaining} days remaining")
                if goal.difficulty:
                    print(f"   🎯 Difficulty: {goal.difficulty.value}")
        
        if completed_goals:
            self.print_header("Completed Goals")
            for goal in completed_goals:
                print(f"✅ {goal.name} - Completed!")
        
        if failed_goals:
            self.print_header("Failed Goals")
            for goal in failed_goals:
                print(f"❌ {goal.name} - Failed")
        
        if not any([active_goals, completed_goals, failed_goals]):
            self.print_warning("No goals set yet. Use 'create-goal' to get started!")
    
    def display_heatmap(self, heatmap: str) -> None:
        """Display activity heatmap."""
        if not heatmap:
            return
        
        print("\n📅 Last 30 Days Activity:")
        # Group into weeks
        weeks = [heatmap[i:i+7] for i in range(0, len(heatmap), 7)]
        for week in weeks:
            print(" ".join(week))
        
        print("\nLegend: ⚫=0 🟢=1 🟡=2 🟠=3 🔴=4+")

# =============================================================================
# APPLICATION CORE
# =============================================================================

class LeetCodeTracker:
    """Main application controller."""
    
    def __init__(self):
        CacheService.ensure_directories()
        
        self.cache = CacheService()
        self.problem_service = ProblemService(self.cache)
        self.stats_service = StatsService(self.problem_service)
        self.goal_service = GoalService(self.cache, self.stats_service)
        self.display = DisplayService()
    
    async def fetch_daily_problems(self, target_date: date, force_refresh: bool = False) -> None:
        """Fetch and display daily problems."""
        problems = await self.problem_service.generate_daily_problems(target_date)
        solved_ids = {sp.problem_id for sp in self.problem_service.get_solved_problems()}
        self.display.display_problems(problems, solved_ids)
    
    async def mark_problem_solved(self, problem_id: str, force_refresh: bool = False) -> None:
        """Mark a problem as solved."""
        all_problems = await self.problem_service.get_all_problems(force_refresh)
        
        if problem_id not in all_problems:
            self.display.print_error(f"Problem {problem_id} not found.")
            return
        
        problem = all_problems[problem_id]
        if self.problem_service.mark_problem_solved(problem_id, problem):
            self.display.print_success(f"Marked '{problem.title}' as solved!")
            self.goal_service.update_goal_progress()
        else:
            self.display.print_warning(f"Problem {problem_id} was already solved.")
    
    def mark_problem_unsolved(self, problem_id: str) -> None:
        """Mark a problem as unsolved."""
        if self.problem_service.mark_problem_unsolved(problem_id):
            self.display.print_success(f"Marked problem {problem_id} as unsolved.")
            self.goal_service.update_goal_progress()
        else:
            self.display.print_warning(f"Problem {problem_id} was not marked as solved.")
    
    def show_solved_problems(self) -> None:
        """Display solved problems."""
        solved = self.problem_service.get_solved_problems()
        self.display.display_solved_problems(solved)
    
    def show_profile(self) -> None:
        """Display user profile with statistics."""
        solved = self.problem_service.get_solved_problems()
        stats = self.stats_service.calculate_stats(solved)
        
        self.display.display_stats(stats)
        self.display.display_heatmap(stats.heatmap)
        
        # Update and show goals
        self.goal_service.update_goal_progress()
        goals = self.goal_service.get_goals()
        self.display.display_goals(goals)
    
    def show_goals(self) -> None:
        """Display goals."""
        self.goal_service.update_goal_progress()
        goals = self.goal_service.get_goals()
        self.display.display_goals(goals)
    
    def create_goal(self, name: str, goal_type: str, target: int, difficulty: str = None) -> None:
        """Create a new goal."""
        try:
            goal_type_enum = GoalType(goal_type)
            difficulty_enum = Difficulty(difficulty) if difficulty else None
            
            goal = self.goal_service.create_goal(name, goal_type_enum, target, difficulty_enum)
            if goal:
                self.display.print_success(f"Created goal: {name}")
            else:
                self.display.print_error("Failed to create goal.")
        except ValueError as e:
            self.display.print_error(f"Invalid goal parameters: {e}")
    
    def setup_starter_goals(self) -> None:
        """Create starter goals for new users."""
        if self.goal_service.create_starter_goals():
            self.display.print_success("Created starter goals!")
        else:
            self.display.print_warning("You already have goals set up.")

# =============================================================================
# COMMAND LINE INTERFACE
# =============================================================================

def parse_date_arg(args: List[str]) -> date:
    """Parse date from command line arguments."""
    if "--today" in args:
        return date.today()
    if "--yesterday" in args:
        return date.today() - timedelta(days=1)
    
    # Support -d YYYY-MM-DD or --date=YYYY-MM-DD
    date_str = None
    if "-d" in args:
        idx = args.index("-d")
        if idx + 1 < len(args):
            date_str = args[idx + 1]
    
    if not date_str:
        for arg in args:
            if arg.startswith("--date="):
                date_str = arg.split("=", 1)[1]
                break
    
    if date_str:
        try:
            return datetime.strptime(date_str, "%Y-%m-%d").date()
        except ValueError:
            print(f"❌ Invalid date format: {date_str}. Using today's date.")
    
    return date.today()

def print_help() -> None:
    """Display help message."""
    print("""
LeetCode Tracker CLI 🚀

A production-ready tool for tracking your LeetCode progress with goals, 
statistics, and daily problem recommendations.

USAGE:
  leetcode fetch [OPTIONS]        Fetch daily random problems
  leetcode mark-done ID           Mark problem as solved
  leetcode mark-undo ID           Unmark problem as solved  
  leetcode solved                 Show solved problems
  leetcode profile                Show stats, streaks and goals
  leetcode goals                  View goals and progress
  leetcode create-goal            Create a new goal
  leetcode quick-start            Create starter goals

OPTIONS for fetch:
  -d YYYY-MM-DD, --date=YYYY-MM-DD   Specific date (default: today)
  --today, --yesterday                Date shortcuts
  --refresh-cache                     Force refresh problem cache

EXAMPLES:
  leetcode fetch                     # Get today's problems
  leetcode fetch -d 2024-01-15       # Get problems for specific date
  leetcode mark-done 42              # Mark problem 42 as solved
  leetcode profile                   # View comprehensive stats
  leetcode create-goal              # Interactive goal creation

QUICK START:
  leetcode quick-start              # Set up starter goals
  leetcode fetch                    # Get daily problems
  leetcode profile                  # Track your progress
""")

async def main() -> None:
    """Main application entry point."""
    if len(sys.argv) < 2:
        print_help()
        return
    
    command = sys.argv[1]
    tracker = LeetCodeTracker()
    
    try:
        if command in ("-h", "--help", "help"):
            print_help()
        
        elif command == "fetch":
            seed_date = parse_date_arg(sys.argv[2:])
            force_refresh = "--refresh-cache" in sys.argv[2:]
            await tracker.fetch_daily_problems(seed_date, force_refresh)
        
        elif command == "mark-done" and len(sys.argv) >= 3:
            force_refresh = "--refresh-cache" in sys.argv
            await tracker.mark_problem_solved(sys.argv[2], force_refresh)
        
        elif command == "mark-undo" and len(sys.argv) == 3:
            tracker.mark_problem_unsolved(sys.argv[2])
        
        elif command == "solved":
            tracker.show_solved_problems()
        
        elif command in ("profile", "stats"):
            tracker.show_profile()
        
        elif command == "goals":
            tracker.show_goals()
        
        elif command == "create-goal":
            # Interactive goal creation
            name = input("Goal name: ").strip()
            print("Goal types: total_solved, daily_streak, difficulty_count, weekly_target")
            goal_type = input("Goal type: ").strip()
            target = int(input("Target: ").strip())
            
            difficulty = None
            if goal_type == "difficulty_count":
                print("Difficulties: Easy, Medium, Hard")
                difficulty = input("Difficulty: ").strip()
            
            tracker.create_goal(name, goal_type, target, difficulty)
        
        elif command == "quick-start":
            tracker.setup_starter_goals()
            print("\nNow run 'leetcode fetch' to get your daily problems!")
        
        else:
            print(f"❌ Unknown command: {command}")
            print_help()
    
    except KeyboardInterrupt:
        print("\n👋 Goodbye!")
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        if os.getenv("DEBUG"):
            raise

if __name__ == "__main__":
    asyncio.run(main())