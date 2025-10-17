#!/bin/bash

# =============================================================================
# CodeTracker AI - AI-Powered Coding Problem Generator
# =============================================================================
# Version: 9.0.0
# Description: Generates LeetCode-style coding problems with AI assistance
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly SCRIPT_NAME="codetracker"
readonly SCRIPT_VERSION="9.0.0"
readonly BASE_DIR="${HOME}/.local/share/codetracker_ai"
readonly DB_FILE="${BASE_DIR}/problems.db"
readonly LOCK_FILE="${BASE_DIR}/codetracker.lock"
readonly EXPORT_DIR="${BASE_DIR}/exports"

# AI Configuration
readonly OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
readonly OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-coder:480b-cloud}"
readonly OLLAMA_TIMEOUT=30

# Problem ID system
readonly PROBLEM_PREFIX="AI"

# UI Colors
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[1;31m'
readonly COLOR_GREEN='\033[1;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[1;34m'
readonly COLOR_CYAN='\033[1;36m'
readonly COLOR_WHITE='\033[1;37m'
readonly COLOR_GRAY='\033[0;90m'
readonly COLOR_MAGENTA='\033[1;35m'

# UI Icons
readonly ICON_SUCCESS="✅"
readonly ICON_ERROR="❌"
readonly ICON_WARNING="⚠️"
readonly ICON_INFO="ℹ️"
readonly ICON_FIRE="🔥"
readonly ICON_CHART="📊"
readonly ICON_EXPORT="📤"

# Difficulty styling
declare -gA DIFFICULTY_ICONS=([Easy]="🟢" [Medium]="🟡" [Hard]="🔴")
declare -gA DIFFICULTY_COLORS=([Easy]="$COLOR_GREEN" [Medium]="$COLOR_YELLOW" [Hard]="$COLOR_RED")

# =============================================================================
# CORE UTILITIES
# =============================================================================

log_error() { echo -e "${COLOR_RED}${ICON_ERROR} $*${COLOR_RESET}" >&2; }
log_success() { echo -e "${COLOR_GREEN}${ICON_SUCCESS} $*${COLOR_RESET}" >&2; }
log_warning() { echo -e "${COLOR_YELLOW}${ICON_WARNING} $*${COLOR_RESET}" >&2; }
log_info() { echo -e "${COLOR_CYAN}${ICON_INFO} $*${COLOR_RESET}" >&2; }
log_debug() { 
    [[ "${DEBUG:-false}" == "true" ]] && echo -e "${COLOR_GRAY}DEBUG: $*${COLOR_RESET}" >&2
}

check_dependencies() {
    local missing_deps=()
    
    for dep in sqlite3 jq curl; do
        command -v "$dep" >/dev/null 2>&1 || missing_deps+=("$dep")
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install with: sudo apt install sqlite3 jq curl  # Ubuntu/Debian"
        log_info "              brew install sqlite3 jq curl      # macOS"
        return 1
    fi
}

ensure_directories() {
    mkdir -p "$BASE_DIR" "$EXPORT_DIR"
}

acquire_lock() {
    local max_attempts=10 attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if (set -o noclobber; echo "$$" > "$LOCK_FILE") 2>/dev/null; then
            trap 'release_lock' EXIT INT TERM
            return 0
        fi
        sleep 0.2
        ((attempt++))
    done
    log_error "Could not acquire lock"
    return 1
}

release_lock() {
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
    trap - EXIT INT TERM
}

with_lock() {
    acquire_lock || return 1
    local result=0
    "$@" || result=$?
    release_lock
    return $result
}

sql_query() {
    local query="$1"
    with_lock sqlite3 -csv -header "$DB_FILE" "$query" 2>/dev/null
}

sql_exec() {
    local query="$1"
    with_lock sqlite3 "$DB_FILE" "$query" 2>/dev/null
}

# =============================================================================
# DATABASE MANAGEMENT
# =============================================================================

init_database() {
    ensure_directories
    
    with_lock sqlite3 "$DB_FILE" << 'EOF'
-- Problems table
CREATE TABLE IF NOT EXISTS problems (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    problem_id TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    difficulty TEXT NOT NULL CHECK (difficulty IN ('Easy', 'Medium', 'Hard')),
    constraints TEXT,
    test_cases TEXT,
    ai_solution TEXT,
    tags TEXT,
    category TEXT DEFAULT 'algorithm',
    time_estimate INTEGER DEFAULT 30,
    generated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_solved BOOLEAN DEFAULT 0
);

-- Solved problems tracking
CREATE TABLE IF NOT EXISTS solved_problems (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    problem_id TEXT NOT NULL,
    solved_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    solve_duration INTEGER DEFAULT 0,
    attempts INTEGER DEFAULT 1,
    FOREIGN KEY (problem_id) REFERENCES problems (problem_id)
);

-- Problem attempts tracking
CREATE TABLE IF NOT EXISTS problem_attempts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    problem_id TEXT NOT NULL,
    attempted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    was_successful BOOLEAN DEFAULT 0,
    attempt_duration INTEGER DEFAULT 0,
    FOREIGN KEY (problem_id) REFERENCES problems (problem_id)
);

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_problems_difficulty ON problems(difficulty);
CREATE INDEX IF NOT EXISTS idx_problems_solved ON problems(is_solved);
CREATE INDEX IF NOT EXISTS idx_problems_category ON problems(category);
CREATE INDEX IF NOT EXISTS idx_solved_time ON solved_problems(solved_at);
CREATE INDEX IF NOT EXISTS idx_attempts_problem ON problem_attempts(problem_id);
CREATE INDEX IF NOT EXISTS idx_attempts_time ON problem_attempts(attempted_at);
EOF
}

# =============================================================================
# PROBLEM GENERATION
# =============================================================================

generate_problem_id() {
    local used_ids new_id
    
    used_ids=$(sql_query "SELECT problem_id FROM problems WHERE problem_id LIKE '${PROBLEM_PREFIX}-%';" 2>/dev/null || true)
    
    for attempt in {1..10}; do
        new_id="${PROBLEM_PREFIX}-$((1000 + RANDOM % 9000))"
        echo "$used_ids" | grep -q "$new_id" || { echo "$new_id"; return 0; }
    done
    
    # Fallback with timestamp
    echo "${PROBLEM_PREFIX}-$(date +%s | tail -c 5)"
}

check_ollama_availability() {
    command -v curl >/dev/null 2>&1 && \
    curl -s --max-time 3 "${OLLAMA_URL}/api/tags" >/dev/null 2>&1
}

generate_ai_problem() {
    local difficulty="${1:-Medium}" category="${2:-}" problem_id="$3"
    
    local category_prompt=""
    [[ -n "$category" && "$category" != "algorithm" ]] && category_prompt=" about $category"
    
    local json_payload=$(cat <<EOF
{
    "model": "$OLLAMA_MODEL",
    "prompt": "Generate a $difficulty level LeetCode-style coding problem$category_prompt. Return ONLY valid JSON with this exact structure:\n\n{\n  \"title\": \"Descriptive Problem Title\",\n  \"description\": \"## Problem Description\\nDetailed problem statement...\\n\\n## Input Format\\nDescription of input...\\n\\n## Output Format\\nDescription of output...\\n\\n## Examples\\nExample 1:\\nInput: ...\\nOutput: ...\\nExplanation: ...\\n\\nExample 2:\\nInput: ...\\nOutput: ...\\nExplanation: ...\",\n  \"difficulty\": \"$difficulty\",\n  \"constraints\": \"1. Constraint 1\\n2. Constraint 2\\n3. Constraint 3\",\n  \"test_cases\": [[\"input1\", \"expected_output1\"], [\"input2\", \"expected_output2\"]],\n  \"ai_solution\": \"def solution(params):\\n    # Complete solution code\\n    pass\",\n  \"tags\": \"array, hash-table, two-pointers\",\n  \"category\": \"algorithm\",\n  \"time_estimate\": 30\n}\n\nIMPORTANT: Choose an appropriate category (algorithm, data-structure, database, system-design, concurrency, math, string, array, dynamic-programming, graph, tree) based on the problem. Return ONLY the JSON object, no other text.",
    "stream": false,
    "options": {
        "temperature": 0.7,
        "num_predict": 2000
    }
}
EOF
)
    
    local response
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        --max-time $OLLAMA_TIMEOUT \
        "${OLLAMA_URL}/api/generate")
    
    if [[ $? -eq 0 && -n "$response" ]]; then
        local json_response=$(echo "$response" | jq -r '.response' | tr -d '\r')
        
        if echo "$json_response" | jq -e . >/dev/null 2>&1; then
            echo "$json_response"
            return 0
        elif [[ "$json_response" =~ (\{[^}]+\}) ]]; then
            json_response="${BASH_REMATCH[1]}"
            echo "$json_response" | jq -e . >/dev/null 2>&1 && echo "$json_response" && return 0
        fi
    fi
    return 1
}

generate_fallback_problem() {
    local difficulty="${1:-Medium}" category="${2:-}"
    
    local time_estimate=25
    [[ "$difficulty" == "Easy" ]] && time_estimate=15
    [[ "$difficulty" == "Hard" ]] && time_estimate=45
    
    # Array of possible categories for variety
    local categories=("algorithm" "data-structure" "array" "string" "math")
    local selected_category="${category:-${categories[$((RANDOM % ${#categories[@]}))]}}"
    
    cat << EOF
{
  "title": "Two Sum - Find Pair Equals Target",
  "description": "## Problem Description\nGiven an array of integers and a target sum, find if there exists a pair of elements that sum to the target value.\n\n## Input Format\n- nums: List of integers\n- target: Integer representing the target sum\n\n## Output Format\n- Boolean: true if a pair exists, false otherwise\n\n## Examples\nExample 1:\nInput: nums = [2, 7, 11, 15], target = 9\nOutput: true\nExplanation: 2 + 7 = 9\n\nExample 2:\nInput: nums = [3, 2, 4], target = 6\nOutput: true\nExplanation: 2 + 4 = 6",
  "difficulty": "$difficulty",
  "constraints": "2 <= nums.length <= 10^4\n-10^9 <= nums[i] <= 10^9\n-10^9 <= target <= 10^9",
  "test_cases": [[[2,7,11,15], 9, true], [[3,2,4], 6, true], [[3,2,4], 8, false]],
  "ai_solution": "def has_pair_sum(nums, target):\n    seen = set()\n    for num in nums:\n        complement = target - num\n        if complement in seen:\n            return True\n        seen.add(num)\n    return False",
  "tags": "array, hash-table, two-sum",
  "category": "$selected_category",
  "time_estimate": $time_estimate
}
EOF
}

insert_problem() {
    local problem_id="$1" title="$2" description="$3" difficulty="$4" constraints="$5"
    local test_cases="$6" ai_solution="$7" tags="$8" category="$9" time_estimate="${10}"
    
    # Escape single quotes for SQL
    title=$(echo "$title" | sed "s/'/''/g")
    description=$(echo "$description" | sed "s/'/''/g")
    constraints=$(echo "$constraints" | sed "s/'/''/g")
    ai_solution=$(echo "$ai_solution" | sed "s/'/''/g")
    tags=$(echo "$tags" | sed "s/'/''/g")
    category=$(echo "$category" | sed "s/'/''/g")
    
    # Validate test_cases JSON
    if [[ "$test_cases" != "[]" && -n "$test_cases" ]]; then
        echo "$test_cases" | jq -e . >/dev/null 2>&1 && test_cases=$(echo "$test_cases" | sed "s/'/''/g")
    fi
    
    sql_exec "
    INSERT INTO problems (
        problem_id, title, description, difficulty, constraints, test_cases,
        ai_solution, tags, category, time_estimate
    ) VALUES (
        '$problem_id', '$title', '$description', '$difficulty', '$constraints', 
        '$test_cases', '$ai_solution', '$tags', '$category', $time_estimate
    )" 2>&1
}

generate_and_store_problems() {
    local count="${1:-3}" category="${2:-}"
    
    echo -e "\n${COLOR_BLUE}Generating $count problems${COLOR_RESET}"
    [[ -n "$category" ]] && echo "Category: $category"
    
    local ai_available=false generated_count=0
    check_ollama_availability && ai_available=true
    
    for ((i=0; i<count; i++)); do
        # Weighted difficulty distribution
        local random_val=$((RANDOM % 100))
        local difficulty="Medium"
        [[ $random_val -lt 40 ]] && difficulty="Easy"
        [[ $random_val -gt 79 ]] && difficulty="Hard"
        
        local problem_id=$(generate_problem_id)
        echo -n "  Generating $difficulty problem... "
        
        local problem_json="" success=false
        
        if [[ "$ai_available" == true ]]; then
            problem_json=$(generate_ai_problem "$difficulty" "$category" "$problem_id")
            [[ $? -eq 0 && -n "$problem_json" ]] && \
            echo "$problem_json" | jq -e . >/dev/null 2>&1 && success=true
        fi
        
        [[ "$success" != true ]] && { 
            problem_json=$(generate_fallback_problem "$difficulty" "$category")
            success=true
        }
        
        if [[ "$success" == true && -n "$problem_json" ]]; then
            local title description constraints test_cases ai_solution tags time_estimate category
            
            title=$(echo "$problem_json" | jq -r '.title // "AI Generated Problem"')
            description=$(echo "$problem_json" | jq -r '.description // "Solve this coding problem."')
            constraints=$(echo "$problem_json" | jq -r '.constraints // ""')
            test_cases=$(echo "$problem_json" | jq -r '.test_cases // "[]"')
            ai_solution=$(echo "$problem_json" | jq -r '.ai_solution // "# Solution code"')
            tags=$(echo "$problem_json" | jq -r '.tags // "algorithm"')
            category=$(echo "$problem_json" | jq -r '.category // "algorithm"')
            time_estimate=$(echo "$problem_json" | jq -r '.time_estimate // 30')
            
            if insert_problem "$problem_id" "$title" "$description" "$difficulty" \
               "$constraints" "$test_cases" "$ai_solution" "$tags" "$category" "$time_estimate"; then
                ((generated_count++))
                echo -e "${COLOR_GREEN}✓${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}✗${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_RED}✗${COLOR_RESET}"
        fi
        
        sleep 1
    done
    
    if [[ $generated_count -gt 0 ]]; then
        log_success "Generated $generated_count/$count problems"
    else
        log_error "Failed to generate any problems"
        return 1
    fi
}

# =============================================================================
# PROBLEM SOLVING INTERFACE
# =============================================================================

cmd_solve() {
    local problem_id="$1"
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; return 1; }

    # Check if problem exists
    local exists
    exists=$(sql_query "SELECT problem_id FROM problems WHERE problem_id = '$problem_id'" | tail -1)
    [[ -z "$exists" ]] && {
        log_error "Problem $problem_id not found"
        return 1
    }

    # Record attempt start
    local attempt_start=$(date +%s)
    sql_exec "INSERT INTO problem_attempts (problem_id, attempted_at) VALUES ('$problem_id', datetime('now'))" >/dev/null 2>&1

    echo
    echo -e "${COLOR_CYAN}💻 Solving Problem: $problem_id${COLOR_RESET}"
    echo "=========================================="

    # Get problem details
    local json
    json=$(sqlite3 "$DB_FILE" -json "SELECT title, description, difficulty, constraints, test_cases FROM problems WHERE problem_id = '$problem_id';" 2>/dev/null)

    local title description difficulty constraints test_cases
    title=$(echo "$json" | jq -r '.[0].title // ""')
    description=$(echo "$json" | jq -r '.[0].description // ""')
    difficulty=$(echo "$json" | jq -r '.[0].difficulty // ""')
    constraints=$(echo "$json" | jq -r '.[0].constraints // ""')
    test_cases=$(echo "$json" | jq -r '.[0].test_cases // ""')

    local icon="${DIFFICULTY_ICONS[$difficulty]}" color="${DIFFICULTY_COLORS[$difficulty]}"

    echo -e "${color}${icon} $title${COLOR_RESET}"
    echo "Difficulty: $difficulty"
    echo

    # Show problem description
    if [[ -n "$description" && "$description" != "NULL" ]]; then
        echo "📖 PROBLEM DESCRIPTION"
        echo "---------------------"
        echo "$description"
        echo
    fi

    if [[ -n "$constraints" && "$constraints" != "NULL" ]]; then
        echo "⚡ CONSTRAINTS"
        echo "-------------"
        echo "$constraints" | sed 's/^[0-9]*\.\?/• /'
        echo
    fi

    echo "⏰ Timer started! Press Enter when you have a solution..."
    read -r

    local attempt_end=$(date +%s)
    local duration=$((attempt_end - attempt_start))

    echo
    echo "What would you like to do?"
    echo "1. Mark as solved ✅"
    echo "2. Try again later 🔄" 
    echo "3. View solution 💡"
    echo "4. Cancel ❌"

    read -r -p "Choose option [1-4]: " choice

    case $choice in
        1)
            # Mark as solved and record successful attempt
            sql_exec "UPDATE problem_attempts SET was_successful = 1, attempt_duration = $duration WHERE id = (SELECT MAX(id) FROM problem_attempts WHERE problem_id = '$problem_id')" >/dev/null 2>&1
            cmd_mark_done "$problem_id"
            ;;
        2)
            log_info "Problem attempt recorded. You can try again later!"
            ;;
        3)
            cmd_solution "$problem_id"
            ;;
        4)
            log_info "Attempt cancelled"
            ;;
        *)
            log_error "Invalid choice"
            ;;
    esac
}

# =============================================================================
# STATISTICS AND ANALYTICS
# =============================================================================

cmd_stats() {
    echo
    echo -e "${COLOR_MAGENTA}${ICON_CHART} Your Coding Statistics${COLOR_RESET}"
    echo "=============================="

    # Basic stats
    local total_problems solved_problems success_rate
    total_problems=$(sql_query "SELECT COUNT(*) FROM problems;" | tail -1 | tr -d '[:space:]"')
    solved_problems=$(sql_query "SELECT COUNT(*) FROM solved_problems;" | tail -1 | tr -d '[:space:]"')
    local total_attempts successful_attempts
    total_attempts=$(sql_query "SELECT COUNT(*) FROM problem_attempts;" | tail -1 | tr -d '[:space:]"')
    successful_attempts=$(sql_query "SELECT COUNT(*) FROM problem_attempts WHERE was_successful = 1;" | tail -1 | tr -d '[:space:]"')
    
    if [[ $total_attempts -gt 0 ]]; then
        success_rate=$((successful_attempts * 100 / total_attempts))
    else
        success_rate=0
    fi

    echo
    echo "📊 Overall Progress"
    echo "------------------"
    echo "Total Problems: $total_problems"
    echo "Solved Problems: $solved_problems"
    echo "Success Rate: $success_rate%"
    echo "Total Attempts: $total_attempts"

    # Streak calculation
    local current_streak=0 longest_streak=0
    local streak_data=$(sql_query "SELECT date(solved_at) as day FROM solved_problems ORDER BY solved_at;" | tail -n +2 | sort -u)
    
    local prev_date=""
    local current_streak_temp=0
    
    while IFS= read -r date; do
        if [[ -n "$date" ]]; then
            date=$(echo "$date" | sed 's/^"//g;s/"$//g')
            if [[ -z "$prev_date" ]]; then
                current_streak_temp=1
            else
                local prev_ts=$(date -d "$prev_date" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$prev_date" +%s 2>/dev/null)
                local curr_ts=$(date -d "$date" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$date" +%s 2>/dev/null)
                local diff=$(( (curr_ts - prev_ts) / 86400 ))
                
                if [[ $diff -eq 1 ]]; then
                    ((current_streak_temp++))
                elif [[ $diff -gt 1 ]]; then
                    current_streak_temp=1
                fi
            fi
            
            [[ $current_streak_temp -gt $longest_streak ]] && longest_streak=$current_streak_temp
            prev_date="$date"
        fi
    done <<< "$streak_data"
    
    current_streak=$current_streak_temp

    echo
    echo "${ICON_FIRE} Streaks"
    echo "-------"
    echo "Current Streak: $current_streak days"
    echo "Longest Streak: $longest_streak days"

    # Weak areas analysis
    echo
    echo "🎯 Weak Areas Analysis"
    echo "---------------------"
    
    local weak_areas=$(sql_query "
        SELECT p.category, 
               COUNT(*) as total_attempts,
               SUM(CASE WHEN pa.was_successful = 1 THEN 1 ELSE 0 END) as successful_attempts,
               ROUND(SUM(CASE WHEN pa.was_successful = 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) as success_rate
        FROM problem_attempts pa
        JOIN problems p ON pa.problem_id = p.problem_id
        GROUP BY p.category
        HAVING COUNT(*) >= 3
        ORDER BY success_rate ASC
        LIMIT 5
    " | tail -n +2)

    if [[ -n "$weak_areas" ]]; then
        while IFS=',' read -r category total successful rate; do
            category=$(echo "$category" | sed 's/^"//g;s/"$//g')
            rate=$(echo "$rate" | sed 's/^"//g;s/"$//g')
            
            if [[ $(echo "$rate < 50" | bc -l 2>/dev/null || echo "$rate < 50") ]]; then
                echo -e "  ${COLOR_RED}• $category: $rate% success ($successful/$total)${COLOR_RESET}"
            elif [[ $(echo "$rate < 70" | bc -l 2>/dev/null || echo "$rate < 70") ]]; then
                echo -e "  ${COLOR_YELLOW}• $category: $rate% success ($successful/$total)${COLOR_RESET}"
            else
                echo -e "  ${COLOR_GREEN}• $category: $rate% success ($successful/$total)${COLOR_RESET}"
            fi
        done <<< "$weak_areas"
    else
        echo "  Not enough data yet. Keep solving problems!"
    fi

    # Difficulty breakdown
    echo
    echo "🎚️ Difficulty Breakdown"
    echo "----------------------"
    
    for difficulty in "Easy" "Medium" "Hard"; do
        local diff_stats=$(sql_query "
            SELECT 
                COUNT(*) as total,
                SUM(CASE WHEN p.is_solved = 1 THEN 1 ELSE 0 END) as solved
            FROM problems p
            WHERE p.difficulty = '$difficulty'
        " | tail -n +2)
        
        if [[ -n "$diff_stats" ]]; then
            IFS=',' read -r total solved <<< "$diff_stats"
            total=$(echo "$total" | sed 's/^"//g;s/"$//g')
            solved=$(echo "$solved" | sed 's/^"//g;s/"$//g')
            
            local icon="${DIFFICULTY_ICONS[$difficulty]}" color="${DIFFICULTY_COLORS[$difficulty]}"
            local percent=0
            [[ $total -gt 0 ]] && percent=$((solved * 100 / total))
            
            echo -e "  $icon ${color}$difficulty${COLOR_RESET}: $solved/$total ($percent%)"
        fi
    done

    # Recent activity
    echo
    echo "📈 Recent Activity"
    echo "-----------------"
    
    local recent_activity=$(sql_query "
        SELECT 
            p.problem_id, 
            p.title, 
            p.difficulty,
            datetime(pa.attempted_at),
            pa.was_successful
        FROM problem_attempts pa
        JOIN problems p ON pa.problem_id = p.problem_id
        ORDER BY pa.attempted_at DESC
        LIMIT 5
    " | tail -n +2)

    if [[ -n "$recent_activity" ]]; then
        while IFS=',' read -r problem_id title difficulty attempted_at was_successful; do
            problem_id=$(echo "$problem_id" | sed 's/^"//g;s/"$//g')
            title=$(echo "$title" | sed 's/^"//g;s/"$//g')
            difficulty=$(echo "$difficulty" | sed 's/^"//g;s/"$//g')
            attempted_at=$(echo "$attempted_at" | sed 's/^"//g;s/"$//g')
            was_successful=$(echo "$was_successful" | sed 's/^"//g;s/"$//g')
            
            local icon="${DIFFICULTY_ICONS[$difficulty]}" color="${DIFFICULTY_COLORS[$difficulty]}"
            local status="❌"; [[ "$was_successful" -eq 1 ]] && status="✅"
            
            echo -e "  $status $icon ${color}$problem_id${COLOR_RESET}: $title"
            echo "     Attempted: $attempted_at"
        done <<< "$recent_activity"
    else
        echo "  No recent activity"
    fi
}

# =============================================================================
# EXPORT FUNCTIONALITY
# =============================================================================

cmd_export() {
    local format="${1:-markdown}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local output_file="$EXPORT_DIR/codetracker_export_${timestamp}.${format}"

    case "$format" in
        "markdown"|"md")
            export_to_markdown "$output_file"
            ;;
        "json")
            export_to_json "$output_file"
            ;;
        "csv")
            export_to_csv "$output_file"
            ;;
        *)
            log_error "Unsupported format: $format. Use markdown, json, or csv."
            return 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        log_success "Exported to: $output_file"
    else
        log_error "Export failed"
        return 1
    fi
}

export_to_markdown() {
    local output_file="$1"
    
    {
        echo "# CodeTracker AI - Problems Export"
        echo "Generated on: $(date)"
        echo

        # Overall stats
        local total_problems solved_problems
        total_problems=$(sql_query "SELECT COUNT(*) FROM problems;" | tail -1 | tr -d '[:space:]"')
        solved_problems=$(sql_query "SELECT COUNT(*) FROM solved_problems;" | tail -1 | tr -d '[:space:]"')
        
        echo "## 📊 Summary"
        echo "- Total Problems: $total_problems"
        echo "- Solved Problems: $solved_problems"
        echo "- Completion Rate: $((solved_problems * 100 / total_problems))%"
        echo

        # Problems list
        echo "## 📚 Problems"
        echo
        
        local problems=$(sql_query "SELECT problem_id, title, difficulty, category, tags, is_solved, time_estimate FROM problems ORDER BY generated_at DESC;")
        
        echo "$problems" | tail -n +2 | while IFS=',' read -r problem_id title difficulty category tags is_solved time_estimate; do
            problem_id=$(echo "$problem_id" | sed 's/^"//g;s/"$//g')
            title=$(echo "$title" | sed 's/^"//g;s/"$//g')
            difficulty=$(echo "$difficulty" | sed 's/^"//g;s/"$//g')
            category=$(echo "$category" | sed 's/^"//g;s/"$//g')
            tags=$(echo "$tags" | sed 's/^"//g;s/"$//g')
            is_solved=$(echo "$is_solved" | sed 's/^"//g;s/"$//g')
            time_estimate=$(echo "$time_estimate" | sed 's/^"//g;s/"$//g')
            
            local status="❌"; [[ "$is_solved" -eq 1 ]] && status="✅"
            
            echo "### $status $title"
            echo "- **ID**: $problem_id"
            echo "- **Difficulty**: $difficulty"
            echo "- **Category**: $category"
            echo "- **Tags**: $tags"
            echo "- **Time Estimate**: ${time_estimate} minutes"
            echo
        done

        # Solved problems with dates
        echo "## ✅ Solved Problems"
        echo
        
        local solved=$(sql_query "
            SELECT p.problem_id, p.title, p.difficulty, date(sp.solved_at)
            FROM solved_problems sp 
            JOIN problems p ON sp.problem_id = p.problem_id 
            ORDER BY sp.solved_at DESC
        " | tail -n +2)
        
        if [[ -n "$solved" ]]; then
            echo "$solved" | while IFS=',' read -r problem_id title difficulty solved_at; do
                problem_id=$(echo "$problem_id" | sed 's/^"//g;s/"$//g')
                title=$(echo "$title" | sed 's/^"//g;s/"$//g')
                difficulty=$(echo "$difficulty" | sed 's/^"//g;s/"$//g')
                solved_at=$(echo "$solved_at" | sed 's/^"//g;s/"$//g')
                
                echo "- **$title** ($problem_id) - $difficulty - Solved: $solved_at"
            done
        else
            echo "No problems solved yet."
        fi

    } > "$output_file"
}

export_to_json() {
    local output_file="$1"
    
    local problems_json=$(sqlite3 "$DB_FILE" -json "SELECT problem_id, title, description, difficulty, constraints, test_cases, ai_solution, tags, category, time_estimate, is_solved, generated_at FROM problems ORDER BY generated_at DESC;" 2>/dev/null)
    local solved_json=$(sqlite3 "$DB_FILE" -json "SELECT sp.problem_id, p.title, p.difficulty, sp.solved_at, sp.attempts FROM solved_problems sp JOIN problems p ON sp.problem_id = p.problem_id ORDER BY sp.solved_at DESC;" 2>/dev/null)
    local attempts_json=$(sqlite3 "$DB_FILE" -json "SELECT problem_id, attempted_at, was_successful, attempt_duration FROM problem_attempts ORDER BY attempted_at DESC;" 2>/dev/null)
    
    cat > "$output_file" << EOF
{
  "export_metadata": {
    "exported_at": "$(date -Iseconds)",
    "version": "$SCRIPT_VERSION",
    "total_problems": $(sql_query "SELECT COUNT(*) FROM problems;" | tail -1 | tr -d '[:space:]"'),
    "solved_problems": $(sql_query "SELECT COUNT(*) FROM solved_problems;" | tail -1 | tr -d '[:space:]"')
  },
  "problems": $problems_json,
  "solved_problems": $solved_json,
  "attempts": $attempts_json
}
EOF
}

export_to_csv() {
    local output_file="$1"
    
    # Export problems
    sql_query "SELECT problem_id, title, difficulty, category, tags, time_estimate, is_solved, generated_at FROM problems ORDER BY generated_at DESC;" > "$output_file"
    
    # Export solved problems
    echo "" >> "$output_file"
    echo "Solved Problems" >> "$output_file"
    sql_query "SELECT p.problem_id, p.title, p.difficulty, sp.solved_at, sp.attempts FROM solved_problems sp JOIN problems p ON sp.problem_id = p.problem_id ORDER BY sp.solved_at DESC;" >> "$output_file"
    
    # Export attempts
    echo "" >> "$output_file"
    echo "Problem Attempts" >> "$output_file"
    sql_query "SELECT problem_id, attempted_at, was_successful, attempt_duration FROM problem_attempts ORDER BY attempted_at DESC;" >> "$output_file"
}

# =============================================================================
# COMMAND HANDLERS
# =============================================================================

cmd_generate() {
    local count="${1:-3}" category="${2:-}"
    
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || { log_error "Count must be a positive integer"; return 1; }
    
    generate_and_store_problems "$count" "$category"
}

cmd_daily() {
    echo
    echo "📅 Daily Coding Challenges"
    echo "=========================="
    
    local unsolved_count
    unsolved_count=$(sql_query "SELECT COUNT(*) FROM problems WHERE is_solved = 0" | tail -1 | tr -d '[:space:]"')
    
    [[ "$unsolved_count" -eq 0 ]] && {
        log_warning "No unsolved problems. Generate new problems first: $SCRIPT_NAME generate"
        return 1
    }
    
    for difficulty in "Easy" "Medium" "Hard"; do
        local problem_data
        problem_data=$(sql_query "
            SELECT problem_id, title, tags, category, time_estimate 
            FROM problems 
            WHERE difficulty = '$difficulty' AND is_solved = 0 
            ORDER BY RANDOM() 
            LIMIT 1
        " | tail -1)
        
        if [[ -n "$problem_data" && "$problem_data" != *"problem_id"* ]]; then
            IFS=',' read -ra fields <<< "$problem_data"
            
            problem_id=$(echo "${fields[0]}" | sed 's/^"//g;s/"$//g')
            title=$(echo "${fields[1]}" | sed 's/^"//g;s/"$//g')
            tags=$(echo "${fields[2]}" | sed 's/^"//g;s/"$//g')
            category=$(echo "${fields[3]}" | sed 's/^"//g;s/"$//g')
            time_estimate=$(echo "${fields[4]}" | sed 's/^"//g;s/"$//g')
            
            local icon="${DIFFICULTY_ICONS[$difficulty]}" color="${DIFFICULTY_COLORS[$difficulty]}"
            
            echo -e "$icon ${color}${difficulty}${COLOR_RESET}: $title"
            echo "     ID: $problem_id | Category: $category | Time: ${time_estimate}min"
            echo "     Tags: $tags"
            echo
        else
            echo -e "${DIFFICULTY_ICONS[$difficulty]} ${DIFFICULTY_COLORS[$difficulty]}${difficulty}: No unsolved problems${COLOR_RESET}"
            echo
        fi
    done
    
    echo "💡 Use '$SCRIPT_NAME solve <problem-id>' to start solving!"
}

cmd_inspect() {
    local problem_id="$1"
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; return 1; }

    # Get JSON output directly from SQLite (solves newline + separator chaos)
    local json
    json=$(sqlite3 "$DB_FILE" -json "SELECT title, description, difficulty, constraints, test_cases, ai_solution, tags, category, time_estimate FROM problems WHERE problem_id = '$problem_id';" 2>/dev/null)

    [[ -z "$json" || "$json" == "[]" ]] && { log_error "Problem $problem_id not found"; return 1; }

    # Extract each field cleanly with jq
    local title description difficulty constraints test_cases ai_solution tags category time_estimate
    title=$(echo "$json" | jq -r '.[0].title // ""')
    description=$(echo "$json" | jq -r '.[0].description // ""')
    difficulty=$(echo "$json" | jq -r '.[0].difficulty // ""')
    constraints=$(echo "$json" | jq -r '.[0].constraints // ""')
    test_cases=$(echo "$json" | jq -r '.[0].test_cases // ""')
    ai_solution=$(echo "$json" | jq -r '.[0].ai_solution // ""')
    tags=$(echo "$json" | jq -r '.[0].tags // ""')
    category=$(echo "$json" | jq -r '.[0].category // ""')
    time_estimate=$(echo "$json" | jq -r '.[0].time_estimate // ""')

    # Normalize difficulty
    case "${difficulty,,}" in
        *easy*) difficulty="Easy" ;;
        *medium*) difficulty="Medium" ;;
        *hard*) difficulty="Hard" ;;
        *) difficulty="Easy" ;;
    esac

    local icon="${DIFFICULTY_ICONS[$difficulty]}" color="${DIFFICULTY_COLORS[$difficulty]}"

    echo
    echo "================================================================================"
    echo -e "${color}${icon} $title${COLOR_RESET}"
    echo "================================================================================"
    echo "ID: $problem_id | Difficulty: $difficulty | Category: $category | Time: ~${time_estimate}min"
    echo "Tags: $tags"
    echo

    if [[ -n "$description" && "$description" != "NULL" ]]; then
        echo "📖 DESCRIPTION"
        echo "--------------"
        echo "$description"
        echo
    fi

    if [[ -n "$constraints" && "$constraints" != "NULL" ]]; then
        echo "⚡ CONSTRAINTS"
        echo "-------------"
        echo "$constraints" | sed 's/^[0-9]*\.\?/• /'
        echo
    fi

    if [[ -n "$test_cases" && "$test_cases" != "[]" && "$test_cases" != "NULL" ]]; then
        echo "🧪 TEST CASES"
        echo "------------"
        if echo "$test_cases" | jq -e . >/dev/null 2>&1; then
            echo "$test_cases" | jq -r '.[] | "  \(.[0]) → \(.[1])"'
        else
            echo "  $test_cases"
        fi
        echo
    fi

    if [[ -n "$ai_solution" && "$ai_solution" != "NULL" ]]; then
        echo "💡 AI SOLUTION"
        echo "-------------"
        echo "$ai_solution"
    fi
}

cmd_solution() {
    local problem_id="$1"
    
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; return 1; }
    
    # Use simpler sqlite3 query without CSV
    local solution
    solution=$(sqlite3 "$DB_FILE" "SELECT ai_solution FROM problems WHERE problem_id = '$problem_id';" 2>/dev/null)
    
    [[ -z "$solution" || "$solution" == "NULL" ]] && {
        log_error "No solution available for $problem_id"
        return 1
    }
    
    echo
    echo "💡 Solution for $problem_id"
    echo "=========================="
    clean_solution=$(echo "$solution" | sed 's/\x1b\[[0-9;]*m//g')
    echo "$clean_solution"
}

cmd_mark_done() {
    local problem_id="$1"
    
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; return 1; }
    
    # Check if problem exists
    local exists
    exists=$(sql_query "SELECT problem_id FROM problems WHERE problem_id = '$problem_id'" | tail -1)
    [[ -z "$exists" ]] && {
        log_error "Problem $problem_id not found"
        return 1
    }
    
    # Check if already solved using solved_problems table
    local already_solved
    already_solved=$(sql_query "SELECT problem_id FROM solved_problems WHERE problem_id = '$problem_id'" | tail -1)
    if [[ -n "$already_solved" ]]; then
        log_warning "Problem $problem_id was already solved"
        return 1
    fi
    
    # Mark as solved
    if sql_exec "INSERT INTO solved_problems (problem_id) VALUES ('$problem_id')" && \
       sql_exec "UPDATE problems SET is_solved = 1 WHERE problem_id = '$problem_id'"; then
        log_success "Marked $problem_id as solved"
        return 0
    else
        log_error "Failed to mark problem as solved"
        return 1
    fi
}

cmd_list() {
    local category_filter="${1:-}"
    local where_clause=""
    
    [[ -n "$category_filter" && "$category_filter" != "all" ]] && where_clause="WHERE category = '$category_filter'"
    
    local problems
    problems=$(sql_query "
        SELECT problem_id, title, difficulty, category, is_solved
        FROM problems 
        $where_clause
        ORDER BY generated_at DESC
    ")
    
    [[ -z "$problems" || $(echo "$problems" | wc -l) -le 1 ]] && {
        log_warning "No problems found"
        return
    }
    
    echo
    echo "📚 Problems"
    echo "==========="
    
    echo "$problems" | tail -n +2 | while IFS=',' read -r problem_id title difficulty category is_solved; do
        # Clean all fields properly
        problem_id=$(echo "$problem_id" | sed 's/^"//g;s/"$//g')
        title=$(echo "$title" | sed 's/^"//g;s/"$//g')
        difficulty=$(echo "$difficulty" | sed 's/^"//g;s/"$//g')
        category=$(echo "$category" | sed 's/^"//g;s/"$//g')
        is_solved=$(echo "$is_solved" | sed 's/^"//g;s/"$//g')
        
        local icon="${DIFFICULTY_ICONS[$difficulty]}" color="${DIFFICULTY_COLORS[$difficulty]}"
        local status="❌"; [[ "$is_solved" -eq 1 ]] && status="✅"
        
        echo -e "$status $icon ${color}$problem_id${COLOR_RESET}: $title"
        echo "     Category: $category"
    done
}

cmd_solved() {
    local solved_problems
    solved_problems=$(sql_query "
        SELECT p.problem_id, p.title, p.difficulty, date(sp.solved_at)
        FROM solved_problems sp 
        JOIN problems p ON sp.problem_id = p.problem_id 
        ORDER BY sp.solved_at DESC
    ")
    
    local problem_count=$(echo "$solved_problems" | tail -n +2 | grep -c .)
    
    [[ $problem_count -eq 0 ]] && {
        log_warning "No problems solved yet"
        return
    }
    
    echo
    echo "✅ Solved Problems"
    echo "================="
    
    echo "$solved_problems" | tail -n +2 | while IFS=',' read -r problem_id title difficulty solved_at; do
        problem_id=$(echo "$problem_id" | sed 's/^"//g;s/"$//g')
        title=$(echo "$title" | sed 's/^"//g;s/"$//g')
        difficulty=$(echo "$difficulty" | sed 's/^"//g;s/"$//g')
        solved_at=$(echo "$solved_at" | sed 's/^"//g;s/"$//g')
        
        local icon="${DIFFICULTY_ICONS[$difficulty]}" color="${DIFFICULTY_COLORS[$difficulty]}"
        echo -e "$icon ${color}$problem_id${COLOR_RESET}: $title - $solved_at"
    done
}

cmd_status() {
    local problem_count solved_count
    problem_count=$(sql_query "SELECT COUNT(*) FROM problems;" | tail -1)
    solved_count=$(sql_query "SELECT COUNT(*) FROM solved_problems;" | tail -1)
    
    echo
    echo "📊 System Status"
    echo "================"
    echo "Total Problems: $problem_count"
    echo "Solved Problems: $solved_count"
    echo "AI Model: $OLLAMA_MODEL"
    
    if check_ollama_availability; then
        echo -e "Ollama Status: ${COLOR_GREEN}Available${COLOR_RESET}"
    else
        echo -e "Ollama Status: ${COLOR_RED}Unavailable${COLOR_RESET}"
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    local command="${1:-interactive}"
    
    check_dependencies || return 1
    ensure_directories
    init_database
    
    case "$command" in
        "generate")
            shift; cmd_generate "$@"
            ;;
        "daily")
            cmd_daily
            ;;
        "solve")
            shift; cmd_solve "$1"
            ;;
        "inspect")
            shift; cmd_inspect "$1"
            ;;
        "solution")
            shift; cmd_solution "$1"
            ;;
        "mark-done")
            shift; cmd_mark_done "$1"
            ;;
        "list")
            shift; cmd_list "$1"
            ;;
        "solved")
            cmd_solved
            ;;
        "stats")
            cmd_stats
            ;;
        "export")
            shift; cmd_export "$1"
            ;;
        "status")
            cmd_status
            ;;
        "interactive"|"")
            echo
            echo -e "${COLOR_CYAN}CodeTracker AI v$SCRIPT_VERSION${COLOR_RESET}"
            echo "========================"
            echo "Commands:"
            echo "  generate [count] [category] - Generate new problems"
            echo "  daily                       - Show daily challenges" 
            echo "  solve <problem-id>          - Start solving a problem"
            echo "  inspect <problem-id>        - View problem details"
            echo "  solution <problem-id>       - Show AI solution"
            echo "  mark-done <problem-id>      - Mark problem as solved"
            echo "  list [category]             - List all problems"
            echo "  solved                      - Show solved problems"
            echo "  stats                       - Detailed statistics & analytics"
            echo "  export [format]             - Export data (markdown/json/csv)"
            echo "  status                      - System status"
            ;;
        "help"|"--help"|"-h")
            echo "Usage: $SCRIPT_NAME [command]"
            echo "Commands: generate, daily, solve, inspect, solution, mark-done, list, solved, stats, export, status, interactive"
            ;;
        *)
            log_error "Unknown command: $command"
            return 1
            ;;
    esac
}

# Run if script is executed directly
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"