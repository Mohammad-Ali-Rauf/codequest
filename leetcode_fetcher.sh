#!/bin/bash

# LeetCode Tracker CLI - Production Ready
# A streamlined CLI tool for tracking LeetCode progress with goals, statistics, and daily problem recommendations.

set -euo pipefail

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================

readonly SCRIPT_NAME="leetcode"
readonly SCRIPT_VERSION="2.3.0"
readonly BASE_DIR="${HOME}/.local/share/leetcode_tracker"
readonly DB_FILE="${BASE_DIR}/leetcode.db"
readonly LEETCODE_URL="https://leetcode.com/graphql"
readonly REQUEST_TIMEOUT=15
readonly MAX_RETRIES=3
readonly LOCK_FILE="${BASE_DIR}/leetcode.lock"
readonly CACHE_TTL=$((7 * 24 * 60 * 60))  # 7 days in seconds

# Goal types & status
readonly GOAL_TOTAL_SOLVED="total_solved"
readonly GOAL_DAILY_STREAK="daily_streak"
readonly GOAL_DIFFICULTY_COUNT="difficulty_count"
readonly GOAL_WEEKLY_TARGET="weekly_target"
readonly STATUS_ACTIVE="active"
readonly STATUS_COMPLETED="completed"
readonly STATUS_FAILED="failed"

# Display configuration
declare -A DIFFICULTY_ICONS=(
    ["Easy"]="🟢"
    ["Medium"]="🟡" 
    ["Hard"]="🔴"
)

declare -A HEATMAP_LEVELS=(
    ["0"]="⚫"
    ["1"]="🟢"
    ["2"]="🟡"
    ["3"]="🟠"
    ["4"]="🔴"
)

# Colors for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_MAGENTA='\033[0;35m'

# =============================================================================
# CORE UTILITIES
# =============================================================================

log_error() { echo -e "${COLOR_RED}❌ $*${COLOR_RESET}" >&2; }
log_success() { echo -e "${COLOR_GREEN}✅ $*${COLOR_RESET}"; }
log_warning() { echo -e "${COLOR_YELLOW}⚠️ $*${COLOR_RESET}"; }
log_info() { echo -e "${COLOR_CYAN}ℹ️ $*${COLOR_RESET}"; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${COLOR_MAGENTA}🐛 $*${COLOR_RESET}" >&2; }

print_header() {
    echo -e "\n${COLOR_BLUE}🎯 $*${COLOR_RESET}"
    echo "=================================================="
}

ensure_directories() {
    mkdir -p "$BASE_DIR"
}

# Thread-safe file operations
acquire_lock() {
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    log_error "Could not acquire lock after $max_attempts attempts"
    return 1
}

release_lock() {
    rm -f "$LOCK_FILE"
}

with_lock() {
    acquire_lock || return 1
    local result=0
    "$@" || result=$?
    release_lock
    return $result
}

# =============================================================================
# DATE UTILITIES
# =============================================================================

get_current_date() { date +%Y-%m-%d; }
get_days_ago() { date -d "$1 days ago" +%Y-%m-%d; }
get_timestamp() { date +%s; }

get_days_diff() {
    local date1="$1" date2="$2"
    local d1 d2 diff
    
    d1=$(date -d "$date1" +%s 2>/dev/null || echo 0)
    d2=$(date -d "$date2" +%s 2>/dev/null || echo 0)
    
    if [[ $d1 -gt 0 && $d2 -gt 0 ]]; then
        diff=$(( (d1 - d2) / 86400 ))
        echo $diff
    else
        echo 0
    fi
}

# =============================================================================
# DATABASE MANAGEMENT
# =============================================================================

init_database() {
    ensure_directories
    
    with_lock sqlite3 "$DB_FILE" << 'EOF'
CREATE TABLE IF NOT EXISTS problems (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    slug TEXT NOT NULL,
    difficulty TEXT NOT NULL,
    ac_rate REAL NOT NULL,
    paid_only INTEGER DEFAULT 0,
    last_fetched TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS solved_problems (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    problem_id TEXT NOT NULL,
    completed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (problem_id) REFERENCES problems (id)
);

CREATE TABLE IF NOT EXISTS goals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    target INTEGER NOT NULL,
    current INTEGER DEFAULT 0,
    difficulty TEXT,
    created_date TEXT NOT NULL,
    deadline TEXT NOT NULL,
    status TEXT DEFAULT 'active'
);

CREATE INDEX IF NOT EXISTS idx_solved_problems_completed_at ON solved_problems(completed_at);
CREATE INDEX IF NOT EXISTS idx_solved_problems_problem_id ON solved_problems(problem_id);
CREATE INDEX IF NOT EXISTS idx_problems_difficulty ON problems(difficulty);
CREATE INDEX IF NOT EXISTS idx_goals_status ON goals(status);
CREATE INDEX IF NOT EXISTS idx_problems_last_fetched ON problems(last_fetched);
EOF
}

sql_query() {
    with_lock sqlite3 -cmd ".timeout 30000" "$DB_FILE" "$1" 2>/dev/null || echo ""
}

# =============================================================================
# API COMMUNICATION
# =============================================================================

fetch_with_retry() {
    local url="$1" data="$2" retry=0 response
    local temp_file
    temp_file=$(mktemp)
    
    while [[ $retry -lt $MAX_RETRIES ]]; do
        log_debug "API attempt $((retry + 1)) to $url"
        
        if curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "User-Agent: LeetCode-Tracker/2.3.0" \
            -d "$data" \
            --connect-timeout $REQUEST_TIMEOUT \
            --max-time $REQUEST_TIMEOUT \
            --fail \
            --compressed \
            -o "$temp_file" \
            "$url" 2>/dev/null && [[ -s "$temp_file" ]]; then
            
            response=$(cat "$temp_file")
            rm -f "$temp_file"
            echo "$response"
            return 0
        fi
        
        retry=$((retry + 1))
        sleep $((2 ** retry))
    done
    
    rm -f "$temp_file"
    log_error "Failed to fetch data from $url after $MAX_RETRIES attempts"
    return 1
}

fetch_all_problems() {
    local query='{
        "query": "query problemsetQuestionList($categorySlug: String, $limit: Int, $skip: Int, $filters: QuestionListFilterInput) { problemsetQuestionList: questionList( categorySlug: $categorySlug limit: $limit skip: $skip filters: $filters ) { total: totalNum questions: data { acRate difficulty frontendQuestionId: questionFrontendId isPaidOnly title titleSlug } } }",
        "variables": {
            "categorySlug": "",
            "skip": 0,
            "limit": 5000,
            "filters": {}
        }
    }'
    
    log_info "Fetching latest problems from LeetCode API..."
    local response start_time
    start_time=$(get_timestamp)
    
    # Capture the API response directly to a file to avoid mixing logs
    local temp_response_file
    temp_response_file=$(mktemp)
    
    if ! curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "User-Agent: LeetCode-Tracker/2.3.0" \
        -H "Accept: application/json" \
        -d "$query" \
        --connect-timeout $REQUEST_TIMEOUT \
        --max-time $REQUEST_TIMEOUT \
        --fail \
        --compressed \
        -o "$temp_response_file" \
        "$LEETCODE_URL" 2>/dev/null || [[ ! -s "$temp_response_file" ]]; then
        
        rm -f "$temp_response_file"
        log_error "Network error: Could not reach LeetCode API"
        return 1
    fi
    
    local end_time=$(get_timestamp)
    log_debug "API request completed in $((end_time - start_time)) seconds"
    
    # Read the response from file
    response=$(cat "$temp_response_file")
    rm -f "$temp_response_file"
    
    if [[ -z "$response" ]]; then
        log_error "Received empty response from LeetCode API"
        return 1
    fi
    
    # Debug: Check what we received
    log_debug "API Response length: ${#response}"
    log_debug "First 200 chars: ${response:0:200}"
    
    # Validate it's proper JSON
    if ! echo "$response" | python3 -c "import json, sys; json.loads(sys.stdin.read())" &>/dev/null; then
        log_error "Invalid JSON response from LeetCode API"
        log_debug "Response start: ${response:0:500}"
        return 1
    fi
    
    # Check if response contains problems data
    local problem_count
    problem_count=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    questions = data.get('data', {}).get('problemsetQuestionList', {}).get('questions', [])
    print(len(questions))
except Exception as e:
    print(f'0')
    sys.exit(1)
")
    
    if [[ "$problem_count" -eq 0 ]]; then
        log_error "Response missing problem data"
        log_debug "Full response: $response"
        return 1
    fi
    
    log_success "Found $problem_count problems from LeetCode"
    
    # Return the clean JSON response
    echo "$response"
}

# =============================================================================
# PROBLEM MANAGEMENT
# =============================================================================

should_refresh_problems() {
    local last_fetched current_time age_seconds
    
    last_fetched=$(sql_query "SELECT strftime('%s', last_fetched) FROM problems ORDER BY last_fetched DESC LIMIT 1;" 2>/dev/null || echo "0")
    current_time=$(get_timestamp)
    
    if [[ "$last_fetched" == "0" || -z "$last_fetched" ]]; then
        log_debug "No problems found in database"
        return 0  # Refresh needed
    fi
    
    age_seconds=$((current_time - last_fetched))
    
    if [[ $age_seconds -gt $CACHE_TTL ]]; then
        log_debug "Problems cache is $((age_seconds / 86400)) days old (beyond TTL)"
        return 0  # Refresh needed
    fi
    
    log_debug "Problems cache is $((age_seconds / 3600)) hours old (within TTL)"
    return 1  # No refresh needed
}

parse_problems_from_response() {
    local response_file="$1"
    
    python3 -c "
import json
import sys

try:
    with open('$response_file', 'r') as f:
        content = f.read()
    
    if not content.strip():
        print('Error: Empty response file', file=sys.stderr)
        sys.exit(1)
    
    data = json.loads(content)
    questions = data.get('data', {}).get('problemsetQuestionList', {}).get('questions', [])
    
    if not questions:
        print('Error: No questions found in response', file=sys.stderr)
        sys.exit(1)
    
    for q in questions:
        # Use the actual field names from the API response
        problem_id = str(q.get('frontendQuestionId', '')).strip()
        title = q.get('title', '').replace('|', '␐').replace(\"'\", \"''\")
        slug = q.get('titleSlug', '')
        difficulty = q.get('difficulty', '')
        ac_rate = float(q.get('acRate', 0)) if q.get('acRate') else 0.0
        paid_only = 1 if q.get('isPaidOnly') else 0
        
        if problem_id and title and slug and difficulty:
            print(f'{problem_id}|{title}|{slug}|{difficulty}|{ac_rate}|{paid_only}')
    
except json.JSONDecodeError as e:
    print(f'JSON decode error: {e}', file=sys.stderr)
    print(f'Content preview: {content[:200]}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'Error parsing problems: {e}', file=sys.stderr)
    sys.exit(1)
"
}

update_problems_database() {
    local problems_response="$1"
    local response_file temp_sql
    
    response_file=$(mktemp)
    temp_sql=$(mktemp)
    
    # Create cleanup function
    cleanup_update_files() {
        rm -f "$response_file" "$temp_sql" 2>/dev/null || true
    }
    
    # Set trap for cleanup
    trap 'cleanup_update_files' EXIT
    
    # Write ONLY the JSON response to file (strip any log messages)
    local clean_json
    clean_json=$(echo "$problems_response" | grep -o '{.*}' | head -1)
    
    if [[ -z "$clean_json" ]]; then
        log_error "Could not extract JSON from response"
        log_debug "Full response: $problems_response"
        return 1
    fi
    
    if ! printf '%s' "$clean_json" > "$response_file"; then
        log_error "Failed to write response to file"
        return 1
    fi
    
    log_debug "Response file created: $response_file"
    log_debug "File size: $(wc -c < "$response_file") bytes"
    log_debug "First 200 chars of clean JSON: $(head -c 200 "$response_file")"
    
    log_info "Updating problems database..."
    
    local processed_count=0
    while IFS='|' read -r id title slug difficulty ac_rate paid_only; do
        [[ -z "$id" ]] && continue
        title="${title//␐/|}"
        echo "INSERT OR REPLACE INTO problems (id, title, slug, difficulty, ac_rate, paid_only, last_fetched) VALUES ('$id', '$title', '$slug', '$difficulty', $ac_rate, $paid_only, CURRENT_TIMESTAMP);" >> "$temp_sql"
        processed_count=$((processed_count + 1))
    done < <(parse_problems_from_response "$response_file")
    
    log_debug "Processed $processed_count problems"
    
    if [[ $processed_count -eq 0 ]]; then
        log_error "No problems were parsed from the response"
        log_debug "First 500 chars of response file: $(head -c 500 "$response_file")"
        return 1
    fi
    
    if with_lock sqlite3 "$DB_FILE" < "$temp_sql" 2>/dev/null; then
        log_success "Updated problems database with $processed_count problems"
    else
        log_error "Failed to update problems database"
        return 1
    fi
}

get_solved_problems() {
    sql_query "
        SELECT p.id, p.title, p.slug, p.difficulty, datetime(sp.completed_at) 
        FROM solved_problems sp 
        JOIN problems p ON sp.problem_id = p.id 
        ORDER BY sp.completed_at DESC
    "
}

mark_problem_solved() {
    local problem_id="$1"
    
    if [[ ! "$problem_id" =~ ^[0-9]+$ ]]; then
        log_error "Invalid problem ID: $problem_id"
        return 1
    fi
    
    if ! sql_query "SELECT 1 FROM problems WHERE id = '$problem_id'" >/dev/null; then
        log_error "Problem $problem_id not found in database"
        return 1
    fi
    
    local existing_count
    existing_count=$(sql_query "SELECT COUNT(*) FROM solved_problems WHERE problem_id = '$problem_id'")
    
    if [[ "$existing_count" -gt 0 ]]; then
        log_warning "Problem $problem_id was already solved"
        return 1
    fi
    
    if sql_query "INSERT INTO solved_problems (problem_id) VALUES ('$problem_id')"; then
        log_success "Marked problem $problem_id as solved"
        update_goal_progress
        return 0
    else
        log_error "Failed to mark problem as solved"
        return 1
    fi
}

mark_problem_unsolved() {
    local problem_id="$1"
    
    if [[ ! "$problem_id" =~ ^[0-9]+$ ]]; then
        log_error "Invalid problem ID: $problem_id"
        return 1
    fi
    
    local deleted_count
    deleted_count=$(sql_query "DELETE FROM solved_problems WHERE problem_id = '$problem_id'; SELECT changes();")
    
    if [[ $deleted_count -gt 0 ]]; then
        log_success "Marked problem $problem_id as unsolved"
        update_goal_progress
        return 0
    else
        log_warning "Problem $problem_id was not marked as solved"
        return 1
    fi
}

# =============================================================================
# STATISTICS & ANALYTICS
# =============================================================================

calculate_stats() {
    local total_solved easy medium hard current_streak longest_streak
    
    total_solved=$(sql_query "SELECT COUNT(*) FROM solved_problems")
    easy=$(sql_query "SELECT COUNT(*) FROM solved_problems sp JOIN problems p ON sp.problem_id = p.id WHERE p.difficulty = 'Easy'")
    medium=$(sql_query "SELECT COUNT(*) FROM solved_problems sp JOIN problems p ON sp.problem_id = p.id WHERE p.difficulty = 'Medium'")
    hard=$(sql_query "SELECT COUNT(*) FROM solved_problems sp JOIN problems p ON sp.problem_id = p.id WHERE p.difficulty = 'Hard'")
    
    current_streak=$(calculate_current_streak)
    longest_streak=$(calculate_longest_streak)
    
    echo "total_solved:$total_solved"
    echo "easy:$easy"
    echo "medium:$medium"
    echo "hard:$hard"
    echo "current_streak:${current_streak:-0}"
    echo "longest_streak:${longest_streak:-0}"
}

calculate_current_streak() {
    sql_query "
        WITH consecutive_days AS (
            SELECT DISTINCT date(completed_at) as solve_date
            FROM solved_problems
            ORDER BY solve_date DESC
        ),
        streaks AS (
            SELECT solve_date,
                   JULIANDAY(solve_date) - JULIANDAY(LAG(solve_date, 1, date(solve_date, '-1 day')) OVER (ORDER BY solve_date DESC)) as gap
            FROM consecutive_days
        ),
        grouped_streaks AS (
            SELECT solve_date,
                   SUM(CASE WHEN gap = 1 THEN 0 ELSE 1 END) OVER (ORDER BY solve_date DESC) as group_id
            FROM streaks
        )
        SELECT COUNT(*) as current_streak
        FROM grouped_streaks
        WHERE group_id = 0
        ORDER BY solve_date DESC
        LIMIT 1
    " 2>/dev/null || echo "0"
}

calculate_longest_streak() {
    sql_query "
        WITH consecutive_days AS (
            SELECT DISTINCT date(completed_at) as solve_date
            FROM solved_problems
            ORDER BY solve_date
        ),
        streaks AS (
            SELECT solve_date,
                   JULIANDAY(solve_date) - JULIANDAY(LAG(solve_date, 1, date(solve_date, '-1 day')) OVER (ORDER BY solve_date)) as gap
            FROM consecutive_days
        ),
        grouped_streaks AS (
            SELECT solve_date,
                   SUM(CASE WHEN gap = 1 THEN 0 ELSE 1 END) OVER (ORDER BY solve_date) as group_id
            FROM streaks
        )
        SELECT MAX(streak_length) as longest_streak
        FROM (
            SELECT group_id, COUNT(*) as streak_length
            FROM grouped_streaks
            GROUP BY group_id
        )
    " 2>/dev/null || echo "0"
}

generate_heatmap() {
    local days=30 heatmap=""
    
    for ((i=days-1; i>=0; i--)); do
        local check_date count
        check_date=$(get_days_ago "$i")
        count=$(sql_query "SELECT COUNT(*) FROM solved_problems WHERE date(completed_at) = '$check_date'")
        
        if [[ $count -ge 4 ]]; then
            heatmap="${heatmap}${HEATMAP_LEVELS[4]}"
        elif [[ $count -ge 3 ]]; then
            heatmap="${heatmap}${HEATMAP_LEVELS[3]}"
        elif [[ $count -ge 2 ]]; then
            heatmap="${heatmap}${HEATMAP_LEVELS[2]}"
        elif [[ $count -ge 1 ]]; then
            heatmap="${heatmap}${HEATMAP_LEVELS[1]}"
        else
            heatmap="${heatmap}${HEATMAP_LEVELS[0]}"
        fi
    done
    
    echo "$heatmap"
}

# =============================================================================
# GOAL MANAGEMENT
# =============================================================================

get_goals() {
    sql_query "
        SELECT id, name, type, target, current, difficulty, created_date, deadline, status 
        FROM goals 
        ORDER BY status, deadline, id
    "
}

create_goal() {
    local name="$1" goal_type="$2" target="$3" difficulty="${4:-}" deadline_days="${5:-30}"
    local deadline created_date
    
    deadline=$(date -d "+$deadline_days days" +%Y-%m-%d)
    created_date=$(get_current_date)
    
    if sql_query "
        INSERT INTO goals (name, type, target, difficulty, created_date, deadline, status)
        VALUES ('$name', '$goal_type', $target, '$difficulty', '$created_date', '$deadline', '$STATUS_ACTIVE')
    "; then
        log_success "Created goal: $name"
        return 0
    else
        log_error "Failed to create goal: $name"
        return 1
    fi
}

update_goal_progress() {
    local total_solved easy medium hard current_streak weekly_solves
    
    total_solved=$(sql_query "SELECT COUNT(*) FROM solved_problems")
    easy=$(sql_query "SELECT COUNT(*) FROM solved_problems sp JOIN problems p ON sp.problem_id = p.id WHERE p.difficulty = 'Easy'")
    medium=$(sql_query "SELECT COUNT(*) FROM solved_problems sp JOIN problems p ON sp.problem_id = p.id WHERE p.difficulty = 'Medium'")
    hard=$(sql_query "SELECT COUNT(*) FROM solved_problems sp JOIN problems p ON sp.problem_id = p.id WHERE p.difficulty = 'Hard'")
    current_streak=$(calculate_current_streak)
    weekly_solves=$(sql_query "SELECT COUNT(*) FROM solved_problems WHERE completed_at >= datetime('now', '-7 days')")
    
    sql_query "
        UPDATE goals 
        SET current = CASE 
            WHEN type = '$GOAL_TOTAL_SOLVED' THEN $total_solved
            WHEN type = '$GOAL_DAILY_STREAK' THEN $current_streak
            WHEN type = '$GOAL_DIFFICULTY_COUNT' AND difficulty = 'Easy' THEN $easy
            WHEN type = '$GOAL_DIFFICULTY_COUNT' AND difficulty = 'Medium' THEN $medium
            WHEN type = '$GOAL_DIFFICULTY_COUNT' AND difficulty = 'Hard' THEN $hard
            WHEN type = '$GOAL_WEEKLY_TARGET' THEN $weekly_solves
            ELSE current
        END,
        status = CASE 
            WHEN current >= target THEN '$STATUS_COMPLETED'
            WHEN deadline < date('now') THEN '$STATUS_FAILED'
            ELSE '$STATUS_ACTIVE'
        END
        WHERE status = '$STATUS_ACTIVE'
    "
}

create_starter_goals() {
    if sql_query "SELECT COUNT(*) FROM goals" | grep -q "^[1-9]"; then
        log_warning "Goals already exist"
        return 1
    fi
    
    create_goal "First Steps" "$GOAL_TOTAL_SOLVED" 5 "" 14
    create_goal "Weekly Warrior" "$GOAL_WEEKLY_TARGET" 3 "" 7
    create_goal "Streak Builder" "$GOAL_DAILY_STREAK" 3 "" 10
    
    log_success "Created starter goals!"
    return 0
}

# =============================================================================
# DISPLAY FUNCTIONS
# =============================================================================

display_problems_from_database() {
    local seed_date="$1"
    
    print_header "Your Daily LeetCode Challenge"
    
    # Check if we have problems in the database
    local problem_count
    problem_count=$(sql_query "SELECT COUNT(*) FROM problems;")
    
    if [[ "$problem_count" -eq 0 ]]; then
        log_error "No problems available in database. Use 'fetch --refresh-cache' first."
        return 1
    fi
    
    log_info "Using database with $problem_count problems"
    
    # Display problems for each difficulty
    for difficulty in "Easy" "Medium" "Hard"; do
        local icon="${DIFFICULTY_ICONS[$difficulty]}"
        
        # Get a random unsolved problem for this difficulty
        local problem
        problem=$(sql_query "
            SELECT p.id, p.title, p.slug, p.ac_rate 
            FROM problems p 
            LEFT JOIN solved_problems sp ON p.id = sp.problem_id 
            WHERE p.difficulty = '$difficulty' 
            AND p.paid_only = 0 
            AND sp.problem_id IS NULL 
            ORDER BY abs(p.id * $(echo "$seed_date" | tr -d '-')) % 10000
            LIMIT 1
        ")
        
        if [[ -n "$problem" && "$problem" =~ \| ]]; then
            IFS='|' read -r id title slug ac_rate <<< "$problem"
            
            local solved_marker=""
            local is_solved
            is_solved=$(sql_query "SELECT COUNT(*) FROM solved_problems WHERE problem_id = '$id'")
            
            if [[ "$is_solved" -gt 0 ]]; then
                solved_marker=" ✅"
            fi
            
            echo -e "\n$icon ${difficulty}${solved_marker}:"
            echo "   ID: $id"
            echo "   Title: $title"
            printf "   Acceptance: %.1f%%\n" "$ac_rate"
            echo "   Link: https://leetcode.com/problems/$slug/"
        else
            echo -e "\n$icon ${difficulty}: No unsolved problems available"
        fi
    done
    
    echo
}

display_solved_problems() {
    local solved_problems
    
    solved_problems=$(get_solved_problems)
    [[ -z "$solved_problems" ]] && log_warning "No problems solved yet." && return
    
    print_header "Solved Problems"
    
    local count=0
    while IFS='|' read -r id title slug difficulty completed_at; do
        local icon="${DIFFICULTY_ICONS[$difficulty]}"
        local date_str=$(date -d "$completed_at" +%Y-%m-%d 2>/dev/null || echo "$completed_at")
        
        echo -e "$icon [$id] $title"
        echo "   Completed: $date_str"
        echo "   Link: https://leetcode.com/problems/$slug/"
        echo
        count=$((count + 1))
    done <<< "$solved_problems"
    
    log_info "Total solved: $count"
}

display_stats() {
    local stats heatmap
    stats=$(calculate_stats)
    heatmap=$(generate_heatmap)
    
    print_header "Your LeetCode Stats"
    
    # Parse stats
    local total_solved easy medium hard current_streak longest_streak
    total_solved=$(echo "$stats" | grep "^total_solved:" | cut -d: -f2)
    easy=$(echo "$stats" | grep "^easy:" | cut -d: -f2)
    medium=$(echo "$stats" | grep "^medium:" | cut -d: -f2)
    hard=$(echo "$stats" | grep "^hard:" | cut -d: -f2)
    current_streak=$(echo "$stats" | grep "^current_streak:" | cut -d: -f2)
    longest_streak=$(echo "$stats" | grep "^longest_streak:" | cut -d: -f2)
    
    echo "Total Solved: $total_solved"
    echo "🟢 Easy:   $easy"
    echo "🟡 Medium: $medium"
    echo "🔴 Hard:   $hard"
    echo -e "\n🔥 Current Streak: $current_streak days"
    echo "🏆 Longest Streak: $longest_streak days"
    
    display_progress_bars "$easy" "$medium" "$hard"
    display_heatmap "$heatmap"
    echo
    display_goals
}

display_progress_bars() {
    local easy="$1" medium="$2" hard="$3"
    local max_count=$(( easy > medium ? (easy > hard ? easy : hard) : (medium > hard ? medium : hard) ))
    max_count=$(( max_count > 0 ? max_count : 1 ))
    
    echo -e "\nProgress:"
    
    for difficulty in "Easy" "Medium" "Hard"; do
        local count bar_length=0 bar=""
        case "$difficulty" in
            "Easy") count="$easy" ;;
            "Medium") count="$medium" ;;
            "Hard") count="$hard" ;;
        esac
        
        bar_length=$(( count * 20 / max_count ))
        bar_length=$(( bar_length > 20 ? 20 : bar_length ))
        for ((i=0; i<bar_length; i++)); do bar="${bar}█"; done
        for ((i=bar_length; i<20; i++)); do bar="${bar}░"; done
        
        local icon="${DIFFICULTY_ICONS[$difficulty]}"
        printf "%s %-6s %s %d\n" "$icon" "$difficulty" "$bar" "$count"
    done
}

display_heatmap() {
    local heatmap="$1"
    [[ -z "$heatmap" ]] && return
    
    echo -e "\n📅 Last 30 Days Activity:"
    for ((i=0; i<30; i+=7)); do
        echo "${heatmap:i:7}" | sed 's/./& /g'
    done
    echo -e "\nLegend: ⚫=0 🟢=1 🟡=2 🟠=3 🔴=4+"
}

display_goals() {
    local goals
    goals=$(get_goals)
    
    local active_goals=() completed_goals=() failed_goals=()
    
    while IFS='|' read -r id name type target current difficulty created_date deadline status; do
        case "$status" in
            "active") active_goals+=("$id|$name|$type|$current|$target|$difficulty|$deadline") ;;
            "completed") completed_goals+=("$id|$name") ;;
            "failed") failed_goals+=("$id|$name") ;;
        esac
    done <<< "$goals"
    
    [[ ${#active_goals[@]} -gt 0 ]] && display_active_goals "${active_goals[@]}"
    [[ ${#completed_goals[@]} -gt 0 ]] && display_completed_goals "${completed_goals[@]}"
    [[ ${#failed_goals[@]} -gt 0 ]] && display_failed_goals "${failed_goals[@]}"
    
    if [[ ${#active_goals[@]} -eq 0 && ${#completed_goals[@]} -eq 0 && ${#failed_goals[@]} -eq 0 ]]; then
        log_warning "No goals set yet. Use 'create-goal' to get started!"
    fi
}

display_active_goals() {
    print_header "Active Goals"
    for goal in "$@"; do
        IFS='|' read -r id name type current target difficulty deadline <<< "$goal"
        
        local percentage=0 bar_length=0 bar=""
        [[ $target -gt 0 ]] && percentage=$(( current * 100 / target ))
        percentage=$(( percentage > 100 ? 100 : percentage ))
        bar_length=$(( percentage * 20 / 100 ))
        
        for ((i=0; i<bar_length; i++)); do bar="${bar}█"; done
        for ((i=bar_length; i<20; i++)); do bar="${bar}░"; done
        
        local days_remaining
        days_remaining=$(get_days_diff "$deadline" "$(get_current_date)")
        
        echo -e "\n$id. $name"
        echo "   $bar $current/$target ($percentage%)"
        echo "   📅 $days_remaining days remaining"
        [[ -n "$difficulty" ]] && echo "   🎯 Difficulty: $difficulty"
    done
}

display_completed_goals() {
    print_header "Completed Goals"
    for goal in "$@"; do
        IFS='|' read -r id name <<< "$goal"
        echo "✅ $name - Completed!"
    done
}

display_failed_goals() {
    print_header "Failed Goals"
    for goal in "$@"; do
        IFS='|' read -r id name <<< "$goal"
        echo "❌ $name - Failed"
    done
}

# =============================================================================
# COMMAND HANDLERS
# =============================================================================

cmd_fetch() {
    local seed_date="$1" force_refresh="$2"
    
    if [[ "$force_refresh" == "true" ]]; then
        # FORCE REFRESH: Fetch from API → Update problems table → Display
        log_info "Refreshing problems from LeetCode API..."
        local api_response
        
        api_response=$(fetch_all_problems)
        
        if [[ $? -eq 0 && -n "$api_response" ]]; then
            if update_problems_database "$api_response"; then
                display_problems_from_database "$seed_date"
            else
                log_error "Failed to update problems database"
                return 1
            fi
        else
            log_error "Failed to fetch valid problems from LeetCode API"
            return 1
        fi
    else
        # SMART FETCH: Check if refresh is needed, then display
        if should_refresh_problems; then
            log_info "Problems cache is stale or missing, refreshing..."
            cmd_fetch "$seed_date" "true"
        else
            # Use existing database
            display_problems_from_database "$seed_date"
        fi
    fi
}

cmd_mark_done() { mark_problem_solved "$1"; }
cmd_mark_undo() { mark_problem_unsolved "$1"; }
cmd_solved() { display_solved_problems; }
cmd_profile() { display_stats; }
cmd_goals() { update_goal_progress; display_goals; }

cmd_create_goal() {
    echo "Creating new goal..."
    read -rp "Goal name: " name
    [[ -z "$name" ]] && { log_error "Goal name cannot be empty"; return 1; }
    
    echo "Goal types: total_solved, daily_streak, difficulty_count, weekly_target"
    read -rp "Goal type: " goal_type
    [[ -z "$goal_type" ]] && { log_error "Goal type cannot be empty"; return 1; }
    
    read -rp "Target: " target
    [[ ! "$target" =~ ^[0-9]+$ ]] && { log_error "Target must be a positive number"; return 1; }
    
    read -rp "Difficulty (Easy/Medium/Hard, leave empty if not applicable): " difficulty
    create_goal "$name" "$goal_type" "$target" "$difficulty"
}

cmd_quick_start() {
    create_starter_goals
    echo -e "\nNow run '$SCRIPT_NAME fetch' to get your daily problems!"
}

cmd_database_status() {
    local problem_count solved_count last_fetched cache_age_days
    
    problem_count=$(sql_query "SELECT COUNT(*) FROM problems;" 2>/dev/null || echo "0")
    solved_count=$(sql_query "SELECT COUNT(*) FROM solved_problems;" 2>/dev/null || echo "0")
    last_fetched=$(sql_query "SELECT last_fetched FROM problems ORDER BY last_fetched DESC LIMIT 1;" 2>/dev/null || echo "Never")
    
    if [[ "$last_fetched" != "Never" ]]; then
        local current_time last_fetched_time
        current_time=$(get_timestamp)
        last_fetched_time=$(date -d "$last_fetched" +%s 2>/dev/null || echo "0")
        cache_age_days=$(( (current_time - last_fetched_time) / 86400 ))
    else
        cache_age_days="N/A"
    fi
    
    log_success "Database Status:"
    echo "  Problems in database: $problem_count"
    echo "  Problems solved: $solved_count"
    echo "  Last fetched: $last_fetched"
    echo "  Cache age: $cache_age_days days"
    echo "  Use 'fetch' for daily problems"
    echo "  Use 'fetch --refresh-cache' to force update from LeetCode API"
}

cmd_clean() {
    log_info "Cleaning up temporary files..."
    rm -f "$LOCK_FILE"
    log_success "Cleanup completed"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

print_help() {
    cat << EOF
LeetCode Tracker CLI 🚀 v$SCRIPT_VERSION

A streamlined tool for tracking your LeetCode progress with goals, 
statistics, and daily problem recommendations.

USAGE:
  $SCRIPT_NAME fetch [OPTIONS]        Fetch daily random problems
  $SCRIPT_NAME mark-done ID           Mark problem as solved
  $SCRIPT_NAME mark-undo ID           Unmark problem as solved  
  $SCRIPT_NAME solved                 Show solved problems
  $SCRIPT_NAME profile                Show stats, streaks and goals
  $SCRIPT_NAME goals                  View goals and progress
  $SCRIPT_NAME create-goal            Create a new goal
  $SCRIPT_NAME quick-start            Create starter goals
  $SCRIPT_NAME database-status        Show database status
  $SCRIPT_NAME clean                  Clean up temporary files

OPTIONS for fetch:
  -d, --date=YYYY-MM-DD              Specific date (default: today)
  --today, --yesterday               Date shortcuts
  --refresh-cache                    Force refresh problems from API

EXAMPLES:
  $SCRIPT_NAME fetch --refresh-cache   # First time: download all problems
  $SCRIPT_NAME fetch                   # Get today's problems (smart cache)
  $SCRIPT_NAME fetch -d 2024-01-15     # Get problems for specific date
  $SCRIPT_NAME mark-done 42            # Mark problem 42 as solved

QUICK START:
  $SCRIPT_NAME fetch --refresh-cache   # Download problems first
  $SCRIPT_NAME quick-start             # Set up starter goals  
  $SCRIPT_NAME fetch                   # Get daily problems
  $SCRIPT_NAME profile                 # Track your progress

ENVIRONMENT:
  DEBUG=true                         Enable debug output
EOF
}

parse_date_arg() {
    local args=("$@") seed_date
    
    for ((i=0; i<${#args[@]}; i++)); do
        case "${args[i]}" in
            "--today")
                echo "$(get_current_date)"
                return
                ;;
            "--yesterday")
                echo "$(get_days_ago 1)"
                return
                ;;
            "-d"|"--date")
                if [[ $((i+1)) -lt ${#args[@]} ]]; then
                    seed_date="${args[i+1]}"
                    if date -d "$seed_date" >/dev/null 2>&1; then
                        echo "$seed_date"
                        return
                    else
                        log_error "Invalid date format: $seed_date. Using today's date."
                        echo "$(get_current_date)"
                        return
                    fi
                fi
                ;;
        esac
    done
    
    echo "$(get_current_date)"
}

main() {
    local command="$1"
    
    case "$command" in
        "-h"|"--help"|"help")
            print_help
            exit 0
            ;;
        "-v"|"--version")
            echo "LeetCode Tracker CLI v$SCRIPT_VERSION"
            exit 0
            ;;
    esac
    
    # Initialize database for all other commands
    init_database
    
    case "$command" in
        "fetch")
            shift
            local seed_date force_refresh="false"
            seed_date=$(parse_date_arg "$@")
            
            for arg in "$@"; do
                if [[ "$arg" == "--refresh-cache" ]]; then
                    force_refresh="true"
                    break
                fi
            done
            
            cmd_fetch "$seed_date" "$force_refresh"
            ;;
        "mark-done")
            shift
            [[ $# -eq 0 ]] && { log_error "Problem ID required"; print_help; exit 1; }
            cmd_mark_done "$1"
            ;;
        "mark-undo")
            shift
            [[ $# -eq 0 ]] && { log_error "Problem ID required"; print_help; exit 1; }
            cmd_mark_undo "$1"
            ;;
        "solved") cmd_solved ;;
        "profile"|"stats") cmd_profile ;;
        "goals") cmd_goals ;;
        "create-goal") cmd_create_goal ;;
        "quick-start") cmd_quick_start ;;
        "database-status"|"cache-status") cmd_database_status ;;
        "clean") cmd_clean ;;
        *)
            log_error "Unknown command: $command"
            print_help
            exit 1
            ;;
    esac
}

# =============================================================================
# ENTRY POINT
# =============================================================================

# Cleanup on exit
cleanup() {
    release_lock
    rm -f "${BASE_DIR}"/tmp.*
}
trap cleanup EXIT

# Check dependencies
for dep in curl sqlite3 python3; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        log_error "Missing required dependency: $dep"
        log_info "Please install $dep to use this script"
        exit 1
    fi
done

# Create base directory
ensure_directories

# Handle signals
trap 'log_error "Operation interrupted"; exit 130;' INT TERM

# Main execution
if [[ $# -eq 0 ]]; then
    print_help
    exit 0
fi

main "$@"