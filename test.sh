#!/bin/bash

# =============================================================================
# CodeQuest - Daily Coding Problem Manager with Vector Similarity
# =============================================================================

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================

readonly SCRIPT_NAME="codequest"
readonly BASE_DIR="${HOME}/.codequest"
readonly DB_FILE="${BASE_DIR}/problems.db"
readonly OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
readonly OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-coder:30b}"
readonly EMBEDDING_MODEL="${EMBEDDING_MODEL:-nomic-embed-text}"

# Qdrant Configuration
readonly QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
readonly QDRANT_COLLECTION="${QDRANT_COLLECTION:-codequest_problems}"
readonly QDRANT_VECTOR_SIZE="${QDRANT_VECTOR_SIZE:-768}"  # Adjust based on your embedding model

# Color codes for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[1;31m'
readonly COLOR_GREEN='\033[1;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[1;34m'
readonly COLOR_CYAN='\033[1;36m'
readonly COLOR_MAGENTA='\033[1;35m'

# Vector similarity threshold (0.0 = identical, 1.0 = completely different)
readonly SIMILARITY_THRESHOLD="${SIMILARITY_THRESHOLD:-0.90}"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log_error()    { echo -e "${COLOR_RED}❌ $*${COLOR_RESET}" >&2; }
log_success()  { echo -e "${COLOR_GREEN}✅ $*${COLOR_RESET}"; }
log_warning()  { echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"; }
log_info()     { echo -e "${COLOR_CYAN}ℹ️  $*${COLOR_RESET}"; }
log_debug()    { [[ "${DEBUG:-false}" == "true" ]] && echo -e "🔧 $*" >&2; }
log_vector()   { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${COLOR_MAGENTA}🧠 $*${COLOR_RESET}" >&2; }

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
# QDRANT VECTOR DATABASE MANAGEMENT
# =============================================================================

# Check if Qdrant is available
is_qdrant_available() {
    curl -s --max-time 3 "${QDRANT_URL}/collections" >/dev/null 2>&1
}

# Initialize Qdrant collection
init_qdrant_collection() {
    if ! is_qdrant_available; then
        log_warning "Qdrant not available at ${QDRANT_URL}. Vector features disabled."
        log_info "Start Qdrant with: docker run -p 6333:6333 qdrant/qdrant"
        return 1
    fi

    # Attempt to create collection (idempotent: safe to run multiple times)
    local create_response=$(curl -s -w "%{http_code}" -X PUT "${QDRANT_URL}/collections/${QDRANT_COLLECTION}" \
        -H "Content-Type: application/json" \
        -d "{
            \"vectors\": {
                \"size\": ${QDRANT_VECTOR_SIZE},
                \"distance\": \"Cosine\"
            }
        }")

    # Extract HTTP status code (last 3 chars)
    local http_code="${create_response: -3}"
    local response_body="${create_response%???}"

    # Success if 200 (created) or 409 (already exists)
    if [[ "$http_code" == "200" || "$http_code" == "409" ]]; then
        if [[ "$http_code" == "200" ]]; then
            log_success "Created Qdrant collection: ${QDRANT_COLLECTION}"
        else
            log_debug "Qdrant collection already exists: ${QDRANT_COLLECTION}"
        fi
        return 0
    else
        log_error "Failed to create Qdrant collection: ${QDRANT_COLLECTION}"
        log_debug "HTTP $http_code: $response_body"
        return 1
    fi
}

# Initialize SQLite database (without vector extensions)
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
CREATE INDEX IF NOT EXISTS idx_problems_category ON problems(category);
CREATE INDEX IF NOT EXISTS idx_problems_created ON problems(created_at);
EOF

    log_debug "Database initialized"
    
    # Initialize Qdrant
    init_qdrant_collection
}

# Execute SQL query and return CSV with headers
sql_query() {
    sqlite3 -csv -header "$DB_FILE" "$1" 2>/dev/null
}

# Execute SQL command without output
sql_exec() {
    sqlite3 "$DB_FILE" "$1" 2>/dev/null
}

# Check if vector functionality is available
is_vector_available() {
    is_qdrant_available
}

# =============================================================================
# VECTOR EMBEDDING FUNCTIONS
# =============================================================================

# Generate embeddings using Ollama
generate_embedding() {
    local text="$1"
    
    # Clean and truncate text for embedding
    text=$(echo "$text" | tr -d '\n' | head -c 2000)
    
    local embedding_json=$(curl -s -X POST -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$EMBEDDING_MODEL\",
            \"prompt\": \"$text\"
        }" "${OLLAMA_URL}/api/embeddings" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "$embedding_json" ]]; then
        echo "$embedding_json" | jq -c '.embedding' 2>/dev/null
    else
        log_vector "Failed to generate embedding for text: ${text:0:50}..."
        return 1
    fi
}

# Generate combined embedding for problem
generate_problem_embedding() {
    local title="$1" description="$2"
    local combined_text="${title}. ${description}"
    
    log_vector "Generating embedding for: ${title:0:30}..."
    generate_embedding "$combined_text"
}

# Store embeddings for a problem in Qdrant
store_problem_embeddings() {
    local problem_id="$1" title="$2" description="$3"
    
    if ! is_vector_available; then
        log_vector "Qdrant not available, skipping embedding storage"
        return 0
    fi
    
    # Validate inputs
    if [[ -z "$problem_id" || -z "$title" ]]; then
        log_vector "Invalid problem data: empty ID or title"
        return 1
    fi
    
    local embedding=$(generate_problem_embedding "$title" "$description")
    
    # Clean the embedding - remove any control characters and validate
    if [[ -n "$embedding" ]] && [[ "$embedding" != "null" ]] && [[ "$embedding" != "[]" ]]; then
        # Remove control characters and validate JSON
        embedding=$(echo "$embedding" | tr -d '\000-\031' | jq -c . 2>/dev/null || echo "")
        
        if [[ -z "$embedding" || "$embedding" == "null" ]]; then
            log_vector "Failed to clean/validate embedding for $problem_id"
            return 1
        fi
        
        # Convert problem_id to a numeric hash for Qdrant
        local numeric_id=$(echo -n "$problem_id" | cksum | cut -d' ' -f1)
        
        log_vector "Generated embedding with length: $(echo "$embedding" | jq 'length') for problem: $problem_id"
        
        # Create the JSON payload safely
        local json_payload=$(jq -n \
            --argjson id "$numeric_id" \
            --argjson vector "$embedding" \
            --arg title "$title" \
            --arg description "$description" \
            --arg problem_id "$problem_id" \
            '{
                points: [{
                    id: $id,
                    vector: $vector,
                    payload: {
                        title: $title,
                        description: $description,
                        problem_id: $problem_id
                    }
                }]
            }')
        
        # Debug the payload
        log_vector "JSON payload length: ${#json_payload}"
        
        # Store in Qdrant
        local response=$(curl -s -X PUT \
            "${QDRANT_URL}/collections/${QDRANT_COLLECTION}/points?wait=true" \
            -H "Content-Type: application/json" \
            -d "$json_payload")
        
        log_vector "Qdrant response: $response"
        
        if echo "$response" | jq -e '.result' >/dev/null 2>&1; then
            log_vector "Stored embeddings in Qdrant for problem: $problem_id (Qdrant ID: $numeric_id)"
            return 0
        else
            log_vector "Failed to store embedding in Qdrant for $problem_id"
            local error_status=$(echo "$response" | jq -r '.status.error // "unknown error"' 2>/dev/null || echo "invalid response")
            log_debug "Qdrant error: $error_status"
            return 1
        fi
    else
        log_vector "Failed to generate valid embedding for $problem_id"
        log_debug "Raw embedding value: '$embedding'"
        return 1
    fi
}

# Check if problem is semantically similar to existing ones using Qdrant
is_semantic_duplicate() {
    local title="$1" description="$2"
    
    if ! is_vector_available; then
        log_vector "Qdrant not available, skipping semantic check"
        return 1
    fi
    
    local new_embedding=$(generate_problem_embedding "$title" "$description")
    if [[ -z "$new_embedding" ]] || [[ "$new_embedding" == "null" ]]; then
        log_vector "Failed to generate embedding for similarity check"
        return 1
    fi
    
    # Use Qdrant for similarity search
    local similar_problems=$(curl -s -X POST \
        "${QDRANT_URL}/collections/${QDRANT_COLLECTION}/points/search" \
        -H "Content-Type: application/json" \
        -d "{
            \"vector\": $new_embedding,
            \"limit\": 3,
            \"score_threshold\": $SIMILARITY_THRESHOLD,
            \"with_payload\": true
        }")
    
    if echo "$similar_problems" | jq -e '.result' >/dev/null 2>&1; then
        local result_count=$(echo "$similar_problems" | jq -r '.result | length')
        if [[ $result_count -gt 0 ]]; then
            local most_similar=$(echo "$similar_problems" | jq -r '.result[0]')
            local similarity_score=$(echo "$most_similar" | jq -r '.score')
            local similar_title=$(echo "$most_similar" | jq -r '.payload.title')
            local similar_problem_id=$(echo "$most_similar" | jq -r '.payload.problem_id')
            
            local similarity_percent=$(echo "scale=2; $similarity_score * 100" | bc)
            log_vector "Similar problem found: '$similar_title' (${similarity_percent}% similar) - ID: $similar_problem_id"
            return 0
        fi
    fi
    
    return 1
}

# Get recent problems for context
get_recent_problems_context() {
    local limit="${1:-5}"
    sqlite3 -csv "$DB_FILE" "
        SELECT title, category, difficulty 
        FROM problems 
        ORDER BY created_at DESC 
        LIMIT $limit" 2>/dev/null | head -c 500
}

# Check vector database health
check_vector_db_health() {
    if ! is_vector_available; then
        echo "Qdrant: ❌ Not available"
        return
    fi
    
    local collection_info=$(curl -s "${QDRANT_URL}/collections/${QDRANT_COLLECTION}")
    local total_problems=$(sql_exec "SELECT COUNT(*) FROM problems")
    local total_vectors=0
    
    if echo "$collection_info" | jq -e '.result' >/dev/null 2>&1; then
        total_vectors=$(echo "$collection_info" | jq -r '.result.vectors_count // 0')
    fi
    
    echo "Vector DB Health:"
    echo "  - Problems: $total_problems"
    echo "  - Qdrant vectors: $total_vectors"
    echo "  - Collection: ${QDRANT_COLLECTION}"
    
    if [[ $total_vectors -lt $((total_problems / 2)) ]] && [[ $total_problems -gt 0 ]]; then
        log_warning "Many problems missing embeddings. Run 'codequest vectors sync'"
    fi
}

# =============================================================================
# AI PROBLEM GENERATION (UNCHANGED)
# =============================================================================

# Check if AI service is available
check_ai_available() {
    log_debug "Checking AI availability at: ${OLLAMA_URL}"
    curl -s --max-time 3 "${OLLAMA_URL}/api/tags" >/dev/null
}

create_ai_prompt() {
    local difficulty="$1"
    local recent_context=$(get_recent_problems_context 3)
    local avoid_titles="$2"  # New parameter for titles to avoid
    
    # Build diversity enforcement
    local diversity_clause=""
    if [[ -n "$avoid_titles" ]]; then
        diversity_clause="CRITICAL: AVOID these specific topics/titles: ${avoid_titles}. Generate something COMPLETELY different in domain and approach."
    fi
    
    cat << EOF
Generate a ${difficulty} level coding problem in JSON format.

CRITICAL INSTRUCTIONS:
- You MUST return ONLY valid JSON, no other text
- Create a narrative around it, to give context with each problem would make it effective for learning
- Make the problem UNIQUE and SEMANTICALLY DIFFERENT from common problems
- Recent problems: ${recent_context}
${diversity_clause}

TOPIC DIVERSITY GUIDELINES:
- Avoid overused topics: Two Sum, FizzBuzz, Palindrome, Binary Search, Fibonacci
- Focus on practical, real-world scenarios across DIFFERENT DOMAINS: healthcare, finance, gaming, IoT, education, logistics, etc.
- Choose interesting topics that fit ${difficulty} difficulty but AVOID domains used in recent problems
- Rotate between different categories: algorithms, data structures, system design, business logic, API design, data processing
- EXPLORE DIFFERENT DOMAINS: If recent problems use "inventory", try "healthcare monitoring", "financial fraud detection", "game physics", "IoT sensor networks"

DOMAIN ROTATION STRATEGY:
- If you see multiple "inventory/management" problems, switch to: scientific computing, real-time systems, bioinformatics, computer graphics
- If you see multiple "validation" problems, switch to: simulation, optimization, machine learning pipelines, distributed systems
- ALWAYS choose a FRESH domain that hasn't been used in recent problems

Use this exact JSON structure:

{
  "title": "Unique and specific problem title reflecting real use case in a FRESH domain",
  "description": "Detailed problem description with narrative context and clear examples. Explain input/output format.",
  "difficulty": "${difficulty}",
  "category": "Choose a specific category like: api design, file processing, validation, optimization, etc.",
  "test_cases": [
    {"input": "example_input_1", "expected": "expected_output_1"},
    {"input": "example_input_2", "expected": "expected_output_2"},
    {"input": "example_input_3", "expected": "expected_output_3"}
  ],
  "solution": "Clean, commented solution code in Python"
}

Make it educational, practical, and test fundamental programming concepts at a ${difficulty} level.
Ensure the problem is semantically AND topically distinct from common coding challenges and recent problems.
EOF
}

# Generate problem using AI with semantic deduplication
generate_problem() {
    local difficulty="${1}"
    local problem_json=""
    local attempts=0
    local max_attempts=3
    
    while [[ $attempts -lt $max_attempts ]]; do
        ((attempts++))
        log_debug "Generation attempt $attempts for $difficulty problem"
        
        # Try AI generation first if available
        if check_ai_available; then
    local avoid_titles=""
    if [[ $attempts -gt 0 ]]; then
        # Get the similar title that was rejected to avoid it
        local recent_titles=$(get_recent_problems_context 5 | grep -o '"title":"[^"]*"' | cut -d'"' -f4 | head -3)
        avoid_titles="$recent_titles"
        log_debug "Avoiding titles on attempt $attempts: $avoid_titles"
    fi
    
    local prompt=$(create_ai_prompt "$difficulty" "$avoid_titles")
    
    # Increase creativity on retry attempts
    local temperature="0.7"
    local top_k="40"
    if [[ $attempts -gt 0 ]]; then
        temperature="0.9"  # More creative on retry
        top_k="60"         # Consider more options
        log_debug "Increased creativity parameters for diversity: temp=$temperature, top_k=$top_k"
    fi
    
    local json_payload=$(jq -n --arg model "$OLLAMA_MODEL" --arg prompt "$prompt" --arg temperature "$temperature" --argjson top_k $top_k '{
        model: $model,
        prompt: $prompt,
        stream: false,
        options: {
            temperature: ($temperature | tonumber),
            top_k: $top_k,
            repeat_penalty: 1.2
        }
    }')
            
            # Set appropriate timeouts based on difficulty
            local timeout=300  # 5 minutes for easy
            if [[ "$difficulty" == "medium" ]]; then
                timeout=480    # 8 minutes for medium
            elif [[ "$difficulty" == "hard" ]]; then
                timeout=600    # 10 minutes for hard
            fi
            
            log_debug "Using timeout: ${timeout}s for $difficulty problem"
            
            local response=$(curl -s -X POST -H "Content-Type: application/json" \
                -d "$json_payload" --max-time $timeout "${OLLAMA_URL}/api/generate")
            
            problem_json=$(echo "$response" | jq -r '.response' 2>/dev/null || echo "")
            
            # Validate JSON and check for semantic duplicates
            if [[ -n "$problem_json" ]] && echo "$problem_json" | jq -e . >/dev/null 2>&1; then
                local title=$(echo "$problem_json" | jq -r '.title // ""' | head -c 200)
                local description=$(echo "$problem_json" | jq -r '.description // ""' | head -c 1000)
                
                if is_semantic_duplicate "$title" "$description"; then
                    log_debug "Semantic duplicate detected, regenerating..."
                    problem_json=""
                    sleep 2
                    continue
                else
                    log_debug "Unique problem generated (semantically distinct)"
                    break
                fi
            else
                log_debug "Invalid JSON response, attempt $attempts failed"
                problem_json=""
            fi
        else
            log_debug "AI not available, using fallback"
            break
        fi
    done
    
    # Use fallback if AI generation failed after all attempts
    if [[ -z "$problem_json" ]]; then
        log_debug "Using fallback problem for $difficulty after $attempts attempts"
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
  "title": "Library Book Due Date Calculator",
  "description": "Create a function that calculates library book due dates. Books are due after 14 days, but skip weekends (Saturday and Sunday).\n\nExample:\nInput: '2024-01-01' (Monday)\nOutput: '2024-01-15' (14 days later, still weekdays)\n\nInput: '2024-01-05' (Friday) \nOutput: '2024-01-23' (Skip weekends)",
  "difficulty": "easy",
  "category": "date manipulation",
  "test_cases": [
    {"input": "'2024-01-01'", "expected": "'2024-01-15'"},
    {"input": "'2024-01-05'", "expected": "'2024-01-23'"}
  ],
  "solution": "from datetime import datetime, timedelta\n\ndef calculate_due_date(checkout_date):\n    date = datetime.strptime(checkout_date, \"%Y-%m-%d\")\n    days_added = 0\n    while days_added < 14:\n        date += timedelta(days=1)\n        if date.weekday() < 5:  # Monday-Friday\n            days_added += 1\n    return date.strftime(\"%Y-%m-%d\")"
}
EOF
            ;;
        "medium")
            cat << 'EOF'
{
  "title": "E-commerce Discount Code Validator",
  "description": "Validate discount codes with rules: must be 8-12 chars, contain mix of letters and numbers, no special chars, and pass checksum validation (sum of char codes mod 10 == 0).\n\nExample:\nInput: 'ABC123XY' \nOutput: true (sum mod 10 == 0)\n\nInput: 'INVALID99'\nOutput: false",
  "difficulty": "medium",
  "category": "validation",
  "test_cases": [
    {"input": "'ABC123XY'", "expected": "true"},
    {"input": "'INVALID99'", "expected": "false"},
    {"input": "'SHORT1'", "expected": "false"}
  ],
  "solution": "def validate_discount_code(code):\n    if len(code) < 8 or len(code) > 12:\n        return False\n    if not code.isalnum():\n        return False\n    if code.isalpha() or code.isdigit():\n        return False\n    \n    checksum = sum(ord(c) for c in code) % 10\n    return checksum == 0"
}
EOF
            ;;
        "hard")
            cat << 'EOF'
{
  "title": "Distributed Cache Consistency Validator",
  "description": "Simulate a distributed cache system with multiple nodes. Implement a consistency check that verifies all nodes have the same data after a series of operations, handling network partitions and delayed updates.\n\nOperations: SET(key, value), GET(key), DELETE(key)\nCheck if all active nodes have consistent state after operations complete.",
  "difficulty": "hard",
  "category": "distributed systems",
  "test_cases": [
    {"input": "nodes=3, ops=[SET('a',1),SET('b',2),GET('a')]", "expected": "consistent"},
    {"input": "nodes=3, ops=[SET('x',1),PARTITION(1),SET('x',2)]", "expected": "inconsistent"}
  ],
  "solution": "class DistributedCache:\n    def __init__(self, node_count):\n        self.nodes = [{} for _ in range(node_count)]\n        self.operations = []\n    \n    def set_value(self, key, value):\n        for node in self.nodes:\n            node[key] = value\n    \n    def check_consistency(self):\n        base_state = self.nodes[0]\n        for node in self.nodes[1:]:\n            if node != base_state:\n                return 'inconsistent'\n        return 'consistent'"
}
EOF
            ;;
    esac
}

# Insert problem into database with embeddings
insert_problem() {
    local problem_id="$1" title="$2" description="$3" difficulty="$4" category="$5" \
          test_cases="$6" solution="$7"
    
    # Escape single quotes for SQL
    title="${title//\'/''}"; description="${description//\'/''}"
    test_cases="${test_cases//\'/''}"; solution="${solution//\'/''}"
    
    local sql_cmd="INSERT INTO problems (problem_id, title, description, difficulty, category, test_cases, solution) 
                   VALUES ('$problem_id', '$title', '$description', '$difficulty', '$category', '$test_cases', '$solution')"
    
    if sql_exec "$sql_cmd"; then
        # Store embeddings in Qdrant (non-blocking)
        if store_problem_embeddings "$problem_id" "$title" "$description"; then
            log_debug "Stored embeddings in Qdrant for problem $problem_id"
        else
            log_debug "Failed to store embeddings in Qdrant for problem $problem_id (continuing anyway)"
        fi
        return 0
    else
        return 1
    fi
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
        log_info "No problems available. Try: $SCRIPT_NAME generate"
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
    echo "   $SCRIPT_NAME show <id>    - View problem details"
    echo "   $SCRIPT_NAME solve <id>   - Mark as solved"
    echo "   $SCRIPT_NAME generate     - Create new problems"
}

# Generate new problems
cmd_generate() {
    echo && echo -e "${COLOR_BLUE}🎯 Generating 3 Problems (Easy, Medium, Hard)${COLOR_RESET}" && echo
    
    local ai_available=false
    check_ai_available && ai_available=true
    [[ "$ai_available" == true ]] && log_info "🤖 AI is available - using AI generation" || log_warning "🤖 AI not available - using fallback problems"
    
    if is_vector_available; then
        log_info "🧠 Qdrant vector similarity checking enabled"
    else
        log_warning "🧠 Qdrant not available - similarity checking disabled"
    fi
    
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
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; echo "Usage: $SCRIPT_NAME show <problem-id>"; return 1; }
    
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
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; echo "Usage: $SCRIPT_NAME solve <problem-id>"; return 1; }
    
    local title=$(sql_query "SELECT title FROM problems WHERE problem_id = '$problem_id'" | tail -1 | tr -d ',"' 2>/dev/null)
    [[ -z "$title" ]] && { log_error "Problem not found: $problem_id"; return 1; }
    
    sql_exec "UPDATE problems SET is_solved = 1, solved_at = CURRENT_TIMESTAMP WHERE problem_id = '$problem_id'" && \
        log_success "Solved: $title" || log_error "Failed to mark as solved"
}

# Show problem solution
cmd_solution() {
    local problem_id="$1"
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; echo "Usage: $SCRIPT_NAME solution <problem-id>"; return 1; }
    
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
    
    echo && check_vector_db_health
}

# Vector management commands
cmd_vectors() {
    local subcommand="${1:-help}"
    
    case "$subcommand" in
        "sync")
    echo && echo -e "${COLOR_BLUE}🔄 Syncing Vector Embeddings to Qdrant${COLOR_RESET}" && echo
    if ! is_vector_available; then
        log_error "Qdrant not available"
        return 1
    fi
    
    local total=$(sql_exec "SELECT COUNT(*) FROM problems")
    local existing=$(curl -s "${QDRANT_URL}/collections/${QDRANT_COLLECTION}" | jq -r '.result.vectors_count // 0')
    local missing=$((total - existing))
    
    if [[ $missing -eq 0 ]]; then
        log_success "All problems already have embeddings in Qdrant"
        return 0
    fi
    
    log_info "Generating embeddings for $missing problems..."
    
    # Use JSON output instead of CSV to avoid parsing issues
    local problems_json=$(sqlite3 -json "$DB_FILE" "
        SELECT problem_id, title, description 
        FROM problems" 2>/dev/null)
    
    local count=0
    local total_to_process=$(echo "$problems_json" | jq length)
    
    echo "$problems_json" | jq -c '.[]' | while IFS= read -r problem; do
        local id=$(echo "$problem" | jq -r '.problem_id')
        local title=$(echo "$problem" | jq -r '.title')
        local description=$(echo "$problem" | jq -r '.description')
        
        # Skip if empty or invalid
        if [[ -z "$id" || "$id" == "null" ]]; then
            continue
        fi
        
        echo -n "Syncing $id... "
        if store_problem_embeddings "$id" "$title" "$description"; then
            echo -e "${COLOR_GREEN}✅${COLOR_RESET}"
            ((count++))
        else
            echo -e "${COLOR_RED}❌${COLOR_RESET}"
        fi
        sleep 1
    done
    
    log_success "Synced embeddings for $count problems to Qdrant"
    ;;
            
        "stats")
            echo && echo -e "${COLOR_BLUE}🧠 Qdrant Vector Database Statistics${COLOR_RESET}" && echo
            check_vector_db_health
            ;;
            
        "similar")
    local problem_id="$2"
    [[ -z "$problem_id" ]] && { log_error "Problem ID required"; return 1; }
    
    if ! is_vector_available; then
        log_error "Qdrant not available"
        return 1
    fi
    
    # Convert to numeric ID for Qdrant lookup
    local numeric_id=$(echo -n "$problem_id" | cksum | cut -d' ' -f1)
    
    # Get the problem's embedding from Qdrant first
    local point_data=$(curl -s "${QDRANT_URL}/collections/${QDRANT_COLLECTION}/points/$numeric_id")
    local vector=$(echo "$point_data" | jq -r '.result.vector // empty')
    
    if [[ -z "$vector" ]]; then
        log_error "Problem $problem_id not found in Qdrant or has no vector"
        return 1
    fi
    
    local similar=$(curl -s -X POST \
        "${QDRANT_URL}/collections/${QDRANT_COLLECTION}/points/search" \
        -H "Content-Type: application/json" \
        -d "{
            \"vector\": $vector,
            \"limit\": 6,
            \"with_payload\": true,
            \"score_threshold\": 0.1
        }")
    
    echo && echo -e "${COLOR_BLUE}🔍 Problems Similar to $problem_id${COLOR_RESET}" && echo
    
    if echo "$similar" | jq -e '.result' >/dev/null 2>&1; then
        echo "$similar" | jq -r '.result[] | select(.payload.problem_id != "'$problem_id'") | "\(.payload.title) (ID: \(.payload.problem_id), similarity: \((.score * 100) | round / 100))"'
    else
        echo "No similar problems found."
    fi
    ;;
            
        "migrate")
            echo && echo -e "${COLOR_BLUE}🚀 Migrating from SQLite-vvec to Qdrant${COLOR_RESET}" && echo
            
            if ! is_vector_available; then
                log_error "Qdrant not available"
                return 1
            fi
            
            log_info "This will copy all existing embeddings from SQLite to Qdrant..."
            log_warning "Make sure Qdrant is running at: ${QDRANT_URL}"
            
            read -p "Continue? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Migration cancelled"
                return 0
            fi
            
            # Initialize Qdrant collection
            init_qdrant_collection || return 1
            
            # Get all problems from SQLite
            local problems=$(sql_query "SELECT problem_id, title, description FROM problems")
            local total=$(echo "$problems" | tail -n +2 | wc -l)
            local count=0
            
            echo "$problems" | tail -n +2 | while IFS=',' read -r id title description; do
                id=$(echo "$id" | tr -d '"')
                title=$(echo "$title" | tr -d '"')
                description=$(echo "$description" | tr -d '"')
                
                echo -n "Migrating $id... "
                if store_problem_embeddings "$id" "$title" "$description"; then
                    echo -e "${COLOR_GREEN}✅${COLOR_RESET}"
                    ((count++))
                else
                    echo -e "${COLOR_RED}❌${COLOR_RESET}"
                fi
                sleep 0.5  # Rate limiting
            done
            
            log_success "Migrated $count/$total problems to Qdrant"
            ;;
            
        *)
            echo && echo -e "${COLOR_BLUE}🧠 Qdrant Vector Management Commands${COLOR_RESET}" && echo
            echo "Usage: $SCRIPT_NAME vectors <command>"
            echo
            echo "Commands:"
            echo "  sync     - Generate embeddings for all problems missing them in Qdrant"
            echo "  stats    - Show Qdrant database statistics"
            echo "  similar <id> - Find problems similar to given problem ID"
            echo "  migrate  - Migrate from SQLite-vvec to Qdrant"
            echo
            echo "Note: Requires Qdrant running at ${QDRANT_URL}"
            ;;
    esac
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
        "vectors")        cmd_vectors "$arg1" ;;
        "help"|"--help"|"-h")
            echo && echo -e "${COLOR_BLUE}CodeQuest - Daily Coding Problems with AI & Vector Similarity${COLOR_RESET}" && echo
            echo "Usage: $SCRIPT_NAME [COMMAND]"
            echo && echo "Commands:"
            echo "  today              Show today's problems (default)"
            echo "  generate           Create 3 new problems (easy, medium, hard)"
            echo "  show <id>          View problem details"
            echo "  solve <id>         Mark problem as solved"
            echo "  solution <id>      Show solution"
            echo "  list [solved|unsolved|all] List problems"
            echo "  progress           Show learning stats"
            echo "  vectors <cmd>      Manage Qdrant vector embeddings"
            echo "  help               Show this help"
            echo && echo "Vector Commands:"
            echo "  vectors sync       Generate missing embeddings in Qdrant"
            echo "  vectors stats      Show Qdrant database health"
            echo "  vectors similar <id> Find similar problems"
            echo "  vectors migrate    Migrate from SQLite-vvec to Qdrant"
            echo && echo "Examples:"
            echo "  $SCRIPT_NAME                    # Show today's challenges"
            echo "  $SCRIPT_NAME generate           # Create 3 new problems"
            echo "  $SCRIPT_NAME show CQ-123456    # View specific problem"
            echo "  $SCRIPT_NAME solve CQ-123456   # Mark as solved"
            echo "  $SCRIPT_NAME vectors migrate   # Migrate to Qdrant"
            ;;
        *) log_error "Unknown command: $command"; echo "Use '$SCRIPT_NAME help' for available commands"; return 1 ;;
    esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"