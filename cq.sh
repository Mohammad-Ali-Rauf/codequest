#!/bin/bash

# =============================================================================
# CodeQuest - Daily Coding Problem Manager
# =============================================================================

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================

readonly SCRIPT_NAME="codequest"
readonly BASE_DIR="${HOME}/.codequest"
readonly DB_FILE="${BASE_DIR}/problems.db"
readonly OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
readonly OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-coder:30b}"

# Color codes for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[1;31m'
readonly COLOR_GREEN='\033[1;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[1;34m'
readonly COLOR_CYAN='\033[1;36m'

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_error()    { echo -e "${COLOR_RED}❌ $*${COLOR_RESET}" >&2; }
log_success()  { echo -e "${COLOR_GREEN}✅ $*${COLOR_RESET}"; }
log_warning()  { echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"; }
log_info()     { echo -e "${COLOR_CYAN}ℹ️  $*${COLOR_RESET}"; }
log_debug()    { [[ "${DEBUG:-false}" == "true" ]] && echo -e "🔧 $*" >&2; }

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check required dependencies
check_dependencies() {
    local deps=("sqlite3" "jq" "curl")
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || {
            log_error "Missing dependency: $dep"
            return 1
        }
    done
}

# Ensure required directories exist
ensure_directories() {
    mkdir -p "$BASE_DIR"
}

# Generate unique problem ID
generate_problem_id() {
    echo "CQ-$(date +%s | tail -c 6)-$(openssl rand -hex 2 2>/dev/null || echo $RANDOM)"
}

# =============================================================================
# DATABASE MANAGEMENT
# =============================================================================

# Initialize SQLite database with problems table
init_database() {
    sqlite3 "$DB_FILE" << 'EOF'
CREATE TABLE IF NOT EXISTS problems (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    problem_id TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    difficulty TEXT NOT NULL CHECK (difficulty IN ('easy', 'medium', 'hard')),
    category TEXT DEFAULT 'algorithm',
    test_cases TEXT,
    solution TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_solved BOOLEAN DEFAULT 0,
    solved_at TIMESTAMP NULL
);
CREATE INDEX IF NOT EXISTS idx_problems_difficulty ON problems(difficulty);
CREATE INDEX IF NOT EXISTS idx_problems_solved ON problems(is_solved);
EOF
}

# Execute SQL query and return CSV with headers
sql_query() {
    sqlite3 -csv -header "$DB_FILE" "$1" 2>/dev/null
}

# Execute SQL command without output
sql_exec() {
    sqlite3 "$DB_FILE" "$1" 2>/dev/null
}

# =============================================================================
# AI PROBLEM GENERATION
# =============================================================================

# Check if AI service is available
check_ai_available() {
    log_debug "Checking AI availability at: ${OLLAMA_URL}"
    curl -s --max-time 3 "${OLLAMA_URL}/api/tags" >/dev/null
}

# Create prompt for AI problem generation based on difficulty
create_ai_prompt() {
    local difficulty="$1"
    
    cat << EOF
Generate a ${difficulty} level coding problem in JSON format. Choose any computer science topic appropriate for ${difficulty} difficulty.

CRITICAL INSTRUCTIONS:
- You MUST return ONLY valid JSON, no other text
- Create a narrative around it, to give context with each problem would make it effective for learning, include the backstory in description field
- Make the problem UNIQUE and DIFFERENT from common problems like "Two Sum" or "FizzBuzz"
- Choose an interesting topic that fits ${difficulty} difficulty

Use this exact JSON structure:

{
  "title": "Unique and specific problem title",
  "description": "Detailed problem description with clear examples. Explain input/output format.",
  "difficulty": "${difficulty}",
  "category": "Choose a relevant category like: algorithms, data structures, strings, arrays, math, etc.",
  "test_cases": [
    {"input": "example_input_1", "expected": "expected_output_1"},
    {"input": "example_input_2", "expected": "expected_output_2"},
    {"input": "example_input_3", "expected": "expected_output_3"}
  ],
  "solution": "Clean, commented solution code in Python"
}

Make it educational, practical, and test fundamental programming concepts at a ${difficulty} level.
Choose a topic that naturally fits this difficulty and will help learners grow.
EOF
}

# Generate problem using AI or fallback
generate_problem() {
    local difficulty="${1}"
    local problem_json=""
    
    # Try AI generation first if available
    if check_ai_available; then
        log_debug "Attempting AI generation for $difficulty problem"
        local prompt=$(create_ai_prompt "$difficulty")
        local json_payload=$(jq -n --arg model "$OLLAMA_MODEL" --arg prompt "$prompt" '{
            model: $model,
            prompt: $prompt,
            stream: false
        }')
        
        # Set appropriate timeouts based on difficulty
        local timeout=300  # 5 minutes for easy
        if [[ "$difficulty" == "medium" ]]; then
            timeout=480    # 7 minutes for medium
        elif [[ "$difficulty" == "hard" ]]; then
            timeout=600    # 10 minutes for hard
        fi
        
        log_debug "Using timeout: ${timeout}s for $difficulty problem"
        
        local response=$(curl -s -X POST -H "Content-Type: application/json" \
            -d "$json_payload" --max-time $timeout "${OLLAMA_URL}/api/generate")
        log_debug "Raw AI response length: ${#response}"
        
        # Extract the response field
        problem_json=$(echo "$response" | jq -r '.response' 2>/dev/null || echo "")
        log_debug "Extracted problem JSON length: ${#problem_json}"
        
        # Validate that we have actual JSON content
        if [[ -n "$problem_json" ]] && echo "$problem_json" | jq -e . >/dev/null 2>&1; then
            log_debug "Valid JSON received for $difficulty problem"
        else
            log_debug "Invalid or empty JSON for $difficulty problem, using fallback"
            problem_json=""
        fi
    fi
    
    # Use fallback if AI generation failed
    if [[ -z "$problem_json" ]]; then
        log_debug "Using fallback problem for $difficulty"
        problem_json=$(generate_fallback_problem "$difficulty")
    fi
    
    echo "$problem_json"
}

# Fallback problems when AI is unavailable
generate_fallback_problem() {
    local difficulty="${1:-medium}"
    
    case "$difficulty" in
        "easy")
            cat << 'EOF'
{
  "title": "Array Element Counter",
  "description": "Write a function that counts how many times each element appears in an array and returns the counts as an object/dictionary.\n\nExample 1:\nInput: [1, 2, 3, 2, 1, 4, 1]\nOutput: {1: 3, 2: 2, 3: 1, 4: 1}\n\nExample 2:\nInput: ['apple', 'banana', 'apple', 'orange']\nOutput: {'apple': 2, 'banana': 1, 'orange': 1}",
  "difficulty": "easy",
  "category": "arrays",
  "test_cases": [
    {"input": "[1, 2, 3, 2, 1, 4, 1]", "expected": "{1: 3, 2: 2, 3: 1, 4: 1}"},
    {"input": "['apple', 'banana', 'apple', 'orange']", "expected": "{'apple': 2, 'banana': 1, 'orange': 1}"},
    {"input": "[True, False, True, True, False]", "expected": "{True: 3, False: 2}"}
  ],
  "solution": "def count_elements(arr):\n    counts = {}\n    for element in arr:\n        counts[element] = counts.get(element, 0) + 1\n    return counts"
}
EOF
            ;;
        "medium")
            cat << 'EOF'
{
  "title": "Binary Tree Level Order Traversal",
  "description": "Given the root of a binary tree, return the level order traversal of its nodes' values (i.e., from left to right, level by level).\n\nExample 1:\nInput: [3,9,20,null,null,15,7]\nOutput: [[3],[9,20],[15,7]]\n\nExample 2:\nInput: [1]\nOutput: [[1]]\n\nExample 3:\nInput: []\nOutput: []",
  "difficulty": "medium",
  "category": "trees",
  "test_cases": [
    {"input": "[3,9,20,null,null,15,7]", "expected": "[[3],[9,20],[15,7]]"},
    {"input": "[1]", "expected": "[[1]]"},
    {"input": "[]", "expected": "[]"}
  ],
  "solution": "from collections import deque\n\ndef level_order(root):\n    if not root:\n        return []\n    result = []\n    queue = deque([root])\n    while queue:\n        level_size = len(queue)\n        current_level = []\n        for _ in range(level_size):\n            node = queue.popleft()\n            current_level.append(node.val)\n            if node.left:\n                queue.append(node.left)\n            if node.right:\n                queue.append(node.right)\n        result.append(current_level)\n    return result"
}
EOF
            ;;
        "hard")
            cat << 'EOF'
{
  "title": "Regular Expression Matching",
  "description": "Implement regular expression matching with support for '.' and '*'.\n\n- '.' Matches any single character\n- '*' Matches zero or more of the preceding element\n\nThe matching should cover the entire input string (not partial).\n\nExample 1:\nInput: s = 'aa', p = 'a'\nOutput: false\nExplanation: 'a' does not match the entire string 'aa'.\n\nExample 2:\nInput: s = 'aa', p = 'a*'\nOutput: true\nExplanation: '*' means zero or more of the preceding element, 'a'. Therefore, by repeating 'a' twice, it becomes 'aa'.\n\nExample 3:\nInput: s = 'ab', p = '.*'\nOutput: true\nExplanation: '.*' means 'zero or more (*) of any character (.)'.",
  "difficulty": "hard",
  "category": "strings",
  "test_cases": [
    {"input": "'aa', 'a'", "expected": "false"},
    {"input": "'aa', 'a*'", "expected": "true"},
    {"input": "'ab', '.*'", "expected": "true"}
  ],
  "solution": "def is_match(s, p):\n    m, n = len(s), len(p)\n    dp = [[False] * (n + 1) for _ in range(m + 1)]\n    dp[0][0] = True\n    for j in range(2, n + 1):\n        if p[j - 1] == '*':\n            dp[0][j] = dp[0][j - 2]\n    for i in range(1, m + 1):\n        for j in range(1, n + 1):\n            if p[j - 1] == '*':\n                dp[i][j] = dp[i][j - 2] or (dp[i - 1][j] and (s[i - 1] == p[j - 2] or p[j - 2] == '.'))\n            else:\n                dp[i][j] = dp[i - 1][j - 1] and (s[i - 1] == p[j - 1] or p[j - 1] == '.')\n    return dp[m][n]"
}
EOF
            ;;
    esac
}

# Insert problem into database
insert_problem() {
    local problem_id="$1" title="$2" description="$3" difficulty="$4" category="$5" \
          test_cases="$6" solution="$7"
    
    # Escape single quotes for SQL
    title="${title//\'/''}"; description="${description//\'/''}"
    test_cases="${test_cases//\'/''}"; solution="${solution//\'/''}"
    
    local sql_cmd="INSERT INTO problems (problem_id, title, description, difficulty, category, test_cases, solution) 
                   VALUES ('$problem_id', '$title', '$description', '$difficulty', '$category', '$test_cases', '$solution')"
    
    sql_exec "$sql_cmd"
}

# =============================================================================
# CORE COMMANDS
# =============================================================================

# Display today's coding challenges
cmd_today() {
    echo && echo -e "${COLOR_BLUE}🚀 Today's Coding Challenges${COLOR_RESET}"
    echo -e "${COLOR_BLUE}═══════════════════════════${COLOR_RESET}" && echo
    
    local unsolved_count=$(sql_exec "SELECT COUNT(*) FROM problems WHERE is_solved = 0")
    
    # Generate new problems if none available
    if [[ "$unsolved_count" -eq 0 ]]; then
        log_info "No unsolved problems found. Generating new problems..."
        cmd_generate
        unsolved_count=$(sql_exec "SELECT COUNT(*) FROM problems WHERE is_solved = 0")
    fi
    
    [[ "$unsolved_count" -eq 0 ]] && {
        log_info "No problems available. Try: ./cq.sh generate"
        return
    }
    
    # Display one problem per difficulty level
    local problems_shown=0
    for difficulty in "easy" "medium" "hard"; do
        local problem_data=$(sqlite3 -json "$DB_FILE" "
            SELECT problem_id, title, description, category 
            FROM problems 
            WHERE difficulty = '$difficulty' AND is_solved = 0 
            ORDER BY RANDOM() LIMIT 1" 2>/dev/null)
        
        if [[ -n "$problem_data" && "$problem_data" != "[]" ]]; then
            local id=$(echo "$problem_data" | jq -r '.[0].problem_id')
            local title=$(echo "$problem_data" | jq -r '.[0].title')
            local description=$(echo "$problem_data" | jq -r '.[0].description')
            local category=$(echo "$problem_data" | jq -r '.[0].category')
            
            case "$difficulty" in
                "easy") color="$COLOR_GREEN"; icon="🟢" ;;
                "medium") color="$COLOR_YELLOW"; icon="🟡" ;;
                "hard") color="$COLOR_RED"; icon="🔴" ;;
            esac
            
            echo -e "$icon ${color}$title${COLOR_RESET}"
            echo "   📋 ID: $id | 🏷️  $category"
            echo "   📝 $(echo "$description" | cut -c 1-100)..."
            echo
            ((problems_shown++))
        fi
    done
    
    local total=$(sql_exec "SELECT COUNT(*) FROM problems")
    local solved=$(sql_exec "SELECT COUNT(*) FROM problems WHERE is_solved = 1")
    
    echo "📊 Progress: $solved/$total problems solved"
    echo && echo "💡 Commands:"
    echo "   codequest show <id>    - View problem details"
    echo "   codequest solve <id>   - Mark as solved"
    echo "   codequest generate     - Create new problems"
}

# Generate new problems
cmd_generate() {
    echo && echo -e "${COLOR_BLUE}🎯 Generating 3 Problems (Easy, Medium, Hard)${COLOR_RESET}" && echo
    
    local ai_available=false
    check_ai_available && ai_available=true
    [[ "$ai_available" == true ]] && log_info "🤖 AI is available - using AI generation" || log_warning "🤖 AI not available - using fallback problems"
    
    local success_count=0
    for difficulty in "easy" "medium" "hard"; do
        echo -n "Creating ${difficulty} problem... "
        
        local problem_json=$(generate_problem "$difficulty")
        
        # Strict validation: must be non-empty AND valid JSON
        if [[ -n "$problem_json" ]] && echo "$problem_json" | jq -e . >/dev/null 2>&1; then
            local problem_id=$(generate_problem_id)
            local title=$(echo "$problem_json" | jq -r '.title // "Coding Problem"')
            local description=$(echo "$problem_json" | jq -r '.description // "Solve this challenge."')
            local extracted_difficulty=$(echo "$problem_json" | jq -r '.difficulty // "medium"')
            local category=$(echo "$problem_json" | jq -r '.category // "algorithm"')
            local test_cases=$(echo "$problem_json" | jq -r '.test_cases // "[]"')
            local solution=$(echo "$problem_json" | jq -r '.solution // "# Solution"')
            
            log_debug "Inserting problem: $title (difficulty: $extracted_difficulty)"
            
            if insert_problem "$problem_id" "$title" "$description" "$extracted_difficulty" "$category" "$test_cases" "$solution"; then
                echo -e "${COLOR_GREEN}✅${COLOR_RESET}" && ((success_count++))
            else
                echo -e "${COLOR_RED}❌${COLOR_RESET}"
                log_debug "Failed to insert problem into database"
            fi
        else
            echo -e "${COLOR_RED}❌${COLOR_RESET}"
            log_debug "Invalid problem JSON for $difficulty"
        fi
        sleep 1
    done
    
    [[ $success_count -gt 0 ]] && log_success "Generated $success_count/3 problems successfully!" || log_error "Failed to generate any problems"
}

# Show problem details
cmd_show() {
    local problem_id="$1"
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; echo "Usage: codequest show <problem-id>"; return 1; }
    
    local problem_data=$(sqlite3 -json "$DB_FILE" "
        SELECT title, description, difficulty, category, test_cases, solution
        FROM problems 
        WHERE problem_id = '$problem_id'" 2>/dev/null)
    
    [[ -z "$problem_data" || "$problem_data" == "[]" ]] && { log_error "Problem not found: $problem_id"; return 1; }
    
    local title=$(echo "$problem_data" | jq -r '.[0].title')
    local description=$(echo "$problem_data" | jq -r '.[0].description')
    local difficulty=$(echo "$problem_data" | jq -r '.[0].difficulty')
    local category=$(echo "$problem_data" | jq -r '.[0].category')
    local test_cases=$(echo "$problem_data" | jq -r '.[0].test_cases')
    local solution=$(echo "$problem_data" | jq -r '.[0].solution')
    
    echo && echo -e "${COLOR_BLUE}📝 $title${COLOR_RESET}"
    echo -e "${COLOR_BLUE}════════════════════════════${COLOR_RESET}" && echo
    echo -e "🎯 Difficulty: $difficulty | 🏷️  Category: $category" && echo
    echo -e "${COLOR_CYAN}Problem Description:${COLOR_RESET}"
    echo -e "$description" | sed 's/\\n/\n/g' && echo
    
    if [[ "$test_cases" != "[]" && "$test_cases" != "null" && -n "$test_cases" ]]; then
        echo -e "${COLOR_YELLOW}🧪 Test Cases:${COLOR_RESET}"
        echo "$test_cases" | jq -r '.[]? | "  Input: \(.input)\n  Expected: \(.expected)\n"' 2>/dev/null
        echo
    fi
}

# Mark problem as solved
cmd_solve() {
    local problem_id="$1"
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; echo "Usage: codequest solve <problem-id>"; return 1; }
    
    local title=$(sql_query "SELECT title FROM problems WHERE problem_id = '$problem_id'" | tail -1 | tr -d ',"' 2>/dev/null)
    [[ -z "$title" ]] && { log_error "Problem not found: $problem_id"; return 1; }
    
    sql_exec "UPDATE problems SET is_solved = 1, solved_at = CURRENT_TIMESTAMP WHERE problem_id = '$problem_id'" && \
        log_success "Solved: $title" || log_error "Failed to mark as solved"
}

# Show problem solution
cmd_solution() {
    local problem_id="$1"
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; echo "Usage: codequest solution <problem-id>"; return 1; }
    
    # Use JSON output to properly handle formatting and special characters
    local solution_data=$(sqlite3 -json "$DB_FILE" "
        SELECT solution FROM problems WHERE problem_id = '$problem_id'" 2>/dev/null)
    
    [[ -z "$solution_data" || "$solution_data" == "[]" ]] && { log_error "No solution available for: $problem_id"; return 1; }
    
    local solution=$(echo "$solution_data" | jq -r '.[0].solution // empty')
    [[ -z "$solution" ]] && { log_error "No solution available for: $problem_id"; return 1; }
    
    echo && echo -e "${COLOR_BLUE}💡 Solution for $problem_id${COLOR_RESET}"
    echo -e "${COLOR_BLUE}══════════════════════════${COLOR_RESET}" && echo
    echo -e "$solution" | sed 's/\\n/\n/g'
}

# List problems with optional filter
cmd_list() {
    local filter="${1:-all}" where_clause=""
    
    case "$filter" in
        "solved") where_clause="WHERE is_solved = 1" ;;
        "unsolved") where_clause="WHERE is_solved = 0" ;;
    esac
    
    echo && echo -e "${COLOR_BLUE}📚 Problems ($filter)${COLOR_RESET}" && echo
    
    local problems=$(sql_query "
        SELECT problem_id, title, difficulty, category, is_solved
        FROM problems $where_clause
        ORDER BY created_at DESC LIMIT 50")
    
    [[ -z "$problems" || $(echo "$problems" | wc -l) -le 1 ]] && { echo "No problems found."; return; }
    
    echo "$problems" | tail -n +2 | while IFS=',' read -r id title difficulty category solved; do
        local status="❌"; [[ "$(echo "$solved" | tr -d '"')" -eq 1 ]] && status="✅"
        case "$difficulty" in
            "easy") color="$COLOR_GREEN" ;;
            "medium") color="$COLOR_YELLOW" ;;
            "hard") color="$COLOR_RED" ;;
        esac
        echo -e "$status ${color}$(echo "$id" | tr -d '"')${COLOR_RESET}: $(echo "$title" | tr -d '"')"
        echo "      🏷️  $(echo "$category" | tr -d '"') | 🎯 $difficulty"
    done
}

# Show progress statistics
cmd_progress() {
    echo && echo -e "${COLOR_BLUE}📊 Your Progress${COLOR_RESET}" && echo
    
    local total=$(sql_exec "SELECT COUNT(*) FROM problems")
    local solved=$(sql_exec "SELECT COUNT(*) FROM problems WHERE is_solved = 1")
    
    echo "✅ Solved: $solved | 📚 Total: $total"
    
    if [[ "$total" -gt 0 ]]; then
        local percent=$((solved * 100 / total))
        echo "📈 Completion: $percent%" && echo
        
        local bar=""; for ((i=0; i<20; i++)); do
            [[ $((i * 5)) -lt $percent ]] && bar+="█" || bar+="░"
        done
        echo "Progress: [$bar]"
    fi
    
    echo && echo -e "${COLOR_CYAN}By Difficulty:${COLOR_RESET}"
    for difficulty in "easy" "medium" "hard"; do
        local stats=$(sql_query "SELECT COUNT(*), SUM(is_solved) FROM problems WHERE difficulty = '$difficulty'" | tail -1)
        IFS=',' read -r total solved <<< "$stats"
        total=$(echo "$total" | tr -d '"' | tr -d '[:space:]'); total=${total:-0}
        solved=$(echo "$solved" | tr -d '"' | tr -d '[:space:]'); solved=${solved:-0}
        
        case "$difficulty" in
            "easy") color="$COLOR_GREEN"; icon="🟢" ;;
            "medium") color="$COLOR_YELLOW"; icon="🟡" ;;
            "hard") color="$COLOR_RED"; icon="🔴" ;;
        esac
        
        local percent=0; [[ $total -gt 0 ]] && percent=$((solved * 100 / total))
        echo -e "  $icon $color$difficulty${COLOR_RESET}: $solved/$total ($percent%)"
    done
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    local command="${1:-today}" arg1="${2:-}"
    
    check_dependencies || return 1
    ensure_directories
    init_database
    
    case "$command" in
        "today")          cmd_today ;;
        "generate"|"gen") cmd_generate ;;
        "show"|"view")    cmd_show "$arg1" ;;
        "solve")          cmd_solve "$arg1" ;;
        "solution"|"sol") cmd_solution "$arg1" ;;
        "list")           cmd_list "$arg1" ;;
        "progress"|"stats") cmd_progress ;;
        "help"|"--help"|"-h")
            echo && echo -e "${COLOR_BLUE}CodeQuest - Daily Coding Problems${COLOR_RESET}" && echo
            echo "Usage: $SCRIPT_NAME [COMMAND]"
            echo && echo "Commands:"
            echo "  today              Show today's problems (default)"
            echo "  generate           Create 3 new problems (easy, medium, hard)"
            echo "  show <id>          View problem details"
            echo "  solve <id>         Mark problem as solved"
            echo "  solution <id>      Show solution"
            echo "  list [solved|unsolved|all] List problems"
            echo "  progress           Show learning stats"
            echo "  help               Show this help"
            echo && echo "Examples:"
            echo "  $SCRIPT_NAME                    # Show today's challenges"
            echo "  $SCRIPT_NAME generate           # Create 3 new problems"
            echo "  $SCRIPT_NAME show CQ-123456    # View specific problem"
            echo "  $SCRIPT_NAME solve CQ-123456   # Mark as solved"
            ;;
        *) log_error "Unknown command: $command"; echo "Use '$SCRIPT_NAME help' for available commands"; return 1 ;;
    esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"