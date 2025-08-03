#!/bin/bash

###
# ./ps4-fpkgi-json.sh http://server.lan/PS4/

# Parameters check
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <serverURL>"
    echo "This sh must reside in the same directory with JSONs and PKGs" 
    exit 1
fi

INPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR+="/"
SCRIPT_DIR="$INPUT_DIR"

# Load environment variables from .env file in script directory
if [ -f "$SCRIPT_DIR.env" ]; then
    export $(grep -v '^#' "$SCRIPT_DIR.env" | xargs)
    echo "Loaded .env file from: $SCRIPT_DIR.env"
else
    echo "Warning: .env file not found at $SCRIPT_DIR.env. IGDB integration will be disabled."
fi

SERVER_URL="$1"
CONTAINER_NAME="openorbis-$(date +%s)"  # Make container name unique
JSON_GAMES="GAMES.json"
JSON_UPDATES="UPDATES.json"
JSON_DLC="DLC.json"
cGames=0
cDlc=0
cUpd=0

# IGDB API configuration
IGDB_API_URL="https://api.igdb.com/v4/games"
IGDB_AUTH_URL="https://id.twitch.tv/oauth2/token"
IGDB_TOKEN=""

# Function to get IGDB authentication token
get_igdb_token() {
    if [ -z "$IGDB_CLIENT_ID" ] || [ -z "$IGDB_CLIENT_SECRET" ]; then
        echo "IGDB credentials not found in .env file. Skipping IGDB integration."
        return 1
    fi

    local response=$(curl -s -X POST "$IGDB_AUTH_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=$IGDB_CLIENT_ID&client_secret=$IGDB_CLIENT_SECRET&grant_type=client_credentials")
    
    IGDB_TOKEN=$(echo "$response" | jq -r '.access_token // empty')
    
    if [ -z "$IGDB_TOKEN" ] || [ "$IGDB_TOKEN" = "null" ]; then
        echo "Failed to get IGDB token. IGDB integration disabled."
        return 1
    fi
    
    echo "IGDB token obtained successfully."
    return 0
}

# Function to search IGDB for game thumbnail
get_igdb_thumbnail() {
    local game_title="$1"
    local title_id="$2"
    
    if [ -z "$IGDB_TOKEN" ]; then
        return 1
    fi
    
    # Check if thumbnail already exists
    if [[ -e "./_img/$title_id.png" ]]; then
        echo "Thumbnail already exists for $title_id, skipping download"
        return 0
    fi
    
    # Clean game title for better search results
    local clean_title=$(echo "$game_title" | sed 's/[^a-zA-Z0-9 ]//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
    
    if [ -z "$clean_title" ]; then
        echo "Empty game title after cleaning, skipping IGDB search."
        return 1
    fi
    
    echo "Searching IGDB for: $clean_title"
    
    local igdb_query="fields name, cover.url; search \"$clean_title\"; limit 5;"
    
    local response=$(curl -s -X POST "$IGDB_API_URL" \
        -H "Client-ID: $IGDB_CLIENT_ID" \
        -H "Authorization: Bearer $IGDB_TOKEN" \
        -d "$igdb_query")
    
    # Check if response contains valid data
    if [ -z "$response" ] || [ "$response" = "[]" ]; then
        echo "No IGDB results found for: $clean_title"
        return 1
    fi
    
    # Extract the first cover URL
    local cover_url=$(echo "$response" | jq -r '.[0].cover.url // empty' 2>/dev/null)
    
    if [ -z "$cover_url" ] || [ "$cover_url" = "null" ]; then
        echo "No cover found in IGDB for: $clean_title"
        return 1
    fi
    
    # Convert to full HTTPS URL (keep default thumb size)
    local full_cover_url="https:${cover_url}"
    
    echo "Found IGDB cover: $full_cover_url"
    
    # Download the thumbnail
    local img_path="./_img/$title_id.png"
    mkdir -p "./_img"
    
    if curl -s -L "$full_cover_url" -o "$img_path"; then
        echo "Successfully downloaded IGDB thumbnail: $img_path"
        return 0
    else
        echo "Failed to download IGDB thumbnail"
        rm -f "$img_path"
        return 1
    fi
}

# Function to extract game name from folder structure
get_game_name_from_folder() {
    local pkg_path="$1"
    local pkg_dir=$(dirname "$pkg_path")
    
    # Look for parent folder containing GAME subfolder
    local current_dir="$pkg_dir"
    while [ "$current_dir" != "$INPUT_DIR" ] && [ "$current_dir" != "/" ]; do
        if [ -d "$current_dir/GAME" ]; then
            # This is the game folder, return its basename
            echo "$(basename "$current_dir")"
            return 0
        fi
        current_dir=$(dirname "$current_dir")
    done
    
    # Fallback: return the immediate parent folder name
    echo "$(basename "$pkg_dir")"
}

# Function to update JSON
update_json() {
    local json_file="$1"
    local key="$2"
    local value="$3"
    
    # Create a new file if it doesn't exist
    if [ ! -f "$json_file" ]; then
        echo '{"DATA": {}}' > "$json_file"
    fi
    
    # Update the JSON file by adding the new value to the "DATA" block
    jq --arg k "$key" --argjson v "$value" '.DATA += {($k): $v}' "$json_file" > tmp.json && mv tmp.json "$json_file"
}

# Function to check if a PKG is already listed in a JSON
pkg_exists_in_json() {
    local pkg_name="$1"
    local json_file="$2"
    
    result=$(grep -Fo "$pkg_name" "$json_file" | wc -l)
    
    # If found, return true (0) else false (1)
    if [ "$result" -gt 0 ]; then
        return 0
    else
        return 1 
    fi
}

cleanup_json() {
    local json_file="$1"

    # Se il file JSON non esiste o è vuoto, esci
    if [ ! -f "$json_file" ] || [ ! -s "$json_file" ]; then
        echo "JSON file $json_file not found or empty. Skipping cleanup."
        return
    fi

    # Read keys (PKG names) from JSON
    original_keys=$(jq -r '.DATA | keys[]' "$json_file")

    kept_keys=""
    deleted_keys=""

    # For every key (PKG name) in the JSON, checks if file exists
    while IFS= read -r key; do
        full_path=${key#$SERVER_URL}  # Rimuove la parte dell'URL per ottenere il percorso del file

        if [ -f "$full_path" ]; then
            kept_keys+="$key"$'\n'
        else
            echo "Record deleted (not found) in $json_file: $full_path"
            deleted_keys+="$key"$'\n'
        fi
    done <<< "$(echo "$original_keys")"

    # Removes invalid records from JSON
    jq --argjson kept_keys "$(echo "$kept_keys" | jq -R -s -c 'split("\n") | map(select(length > 0))')" '
        {DATA: ( .DATA | to_entries | map(select(.key as $key | $kept_keys | index($key))) | from_entries )}' \
        "$json_file" > tmp.json && mv tmp.json "$json_file"

    echo "Cleanup completed for $json_file"
}

# Create json files if they dont exist
if [ ! -f "$JSON_GAMES" ]; then
    echo '{"DATA": {}}' > "$JSON_GAMES"
fi
if [ ! -f "$JSON_UPDATES" ]; then
    echo '{"DATA": {}}' > "$JSON_UPDATES"
fi
if [ ! -f "$JSON_DLC" ]; then
    echo '{"DATA": {}}' > "$JSON_DLC"
fi

# Initialize IGDB
echo "Initializing IGDB integration..."
get_igdb_token

echo "Starting OpenOrbis Docker container..."
container_id=$(docker run --rm -dit --name "$CONTAINER_NAME" -w /workspace -u $(id -u):$(id -g) -v "$(realpath "$INPUT_DIR")":/workspace openorbisofficial/toolchain)

echo "Container started: $container_id"

while read -r pkg; do
    pkg_name=$(basename "$pkg")
    pkg_dir=$(dirname "$pkg")
    
    # Check if pkg is already in jsons
    if pkg_exists_in_json "$pkg_name" "$JSON_GAMES" || pkg_exists_in_json "$pkg_name" "$JSON_UPDATES" || pkg_exists_in_json "$pkg_name" "$JSON_DLC"; then
        echo "Skip: $pkg_name already listed in JSONs."
        continue
    fi
    
    # Check if pkg_dir is subdir of path
    if [[ "$pkg_dir" == "$INPUT_DIR"* ]]; then
        # if yes, take the subdir
        subdir=$(echo "$pkg_dir" | sed "s|$INPUT_DIR||")
        # If subdir is not empty, adds subdir to pkg name
        if [[ -n "$subdir" ]]; then
            pkg_name="$subdir/$pkg_name"
        else
            pkg_name="$pkg_name"
        fi
    else
        pkg_name="$pkg_name"
    fi

    # Execute command in container and saves output in tempfile1
    docker exec "$CONTAINER_NAME" /lib/OpenOrbisSDK/bin/linux/PkgTool.Core pkg_listentries "/workspace/$pkg_name" > ./tmpfile1

    param_sfo_index=$(docker exec "$CONTAINER_NAME" grep "PARAM_SFO" /workspace/tmpfile1 | awk '{print $4}')

    sfo_file="/workspace/${pkg_name}.sfo"
    docker exec "$CONTAINER_NAME" /lib/OpenOrbisSDK/bin/linux/PkgTool.Core pkg_extractentry "/workspace/$pkg_name" "$param_sfo_index" "$sfo_file"

    docker exec "$CONTAINER_NAME" /lib/OpenOrbisSDK/bin/linux/PkgTool.Core sfo_listentries "$sfo_file" > ./tmpfile

    category=$(docker exec "$CONTAINER_NAME" grep "^CATEGORY " /workspace/tmpfile | awk -F'=' '{print $2}' | tr -d ' ')
    title_id=$(docker exec "$CONTAINER_NAME" grep "^TITLE_ID " /workspace/tmpfile | awk -F'=' '{print $2}' | tr -d ' ')
    title=$(docker exec "$CONTAINER_NAME" grep "^TITLE " /workspace/tmpfile | awk -F'=' '{print $2}' | sed 's/^ *//;s/ *$//')    
    version=$(docker exec "$CONTAINER_NAME" grep "^APP_VER " /workspace/tmpfile | awk -F'=' '{print $2}' | tr -d ' ')
    release_tmp=$(docker exec "$CONTAINER_NAME" grep "^PUBTOOLINFO " /workspace/tmpfile | grep -o "c_date=[0-9]*" | cut -d'=' -f2)
    release=$(echo "$release_tmp" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\2-\3-\1/')
    size=$(stat -c %s "$pkg")
    content_id=$(docker exec "$CONTAINER_NAME" grep "^CONTENT_ID " /workspace/tmpfile | awk -F'=' '{print $2}' | tr -d ' ')
    region="${content_id:0:1}"
        if [[ "$region" == "J" ]]; then 
        region="JAP"
    elif [[ "$region" == "E" ]]; then
        region="EUR"
    elif [[ "$region" == "U" ]]; then
        region="USA"
    else 
        region="null"
    fi

    cover_url="$SERVER_URL"
    cover_url+="_img/$title_id.png"
    pkg_url="$SERVER_URL$pkg_name"
    
    # Try to get thumbnail from IGDB first
    igdb_success=0
    if [[ "$category" == "gd" ]]; then
        # Check if image already exists first
        if [[ -e "./_img/$title_id.png" ]]; then
            echo "Cover already exists: ./_img/$title_id.png"
            igdb_success=1
        else
            # For games, try to get game name from folder structure first
            folder_game_name=$(get_game_name_from_folder "$pkg")
            
            # Try IGDB with folder name first, then with SFO title
            if get_igdb_thumbnail "$folder_game_name" "$title_id"; then
                igdb_success=1
                echo "Used IGDB thumbnail for folder name: $folder_game_name"
            elif get_igdb_thumbnail "$title" "$title_id"; then
                igdb_success=1
                echo "Used IGDB thumbnail for SFO title: $title"
            fi
        fi
    fi
    
    # Fallback to original method if IGDB failed and image doesn't exist
    if [[ $igdb_success -eq 0 ]] && [[ ! -e "./_img/$title_id.png" ]]; then
        echo "IGDB thumbnail not found, using original extraction method..."
        icon0_index=$(docker exec "$CONTAINER_NAME" grep 'ICON0_PNG' /workspace/tmpfile1 | awk '{print $4}')
        
        # If ICON0 is empty, try PIC0
        if [[ -z "$icon0_index" ]]; then
            icon0_index=$(docker exec "$CONTAINER_NAME" grep 'PIC0_PNG' /workspace/tmpfile1 | awk '{print $4}')
        fi
        
        if [[ -n "$icon0_index" ]]; then
            docker exec "$CONTAINER_NAME" /lib/OpenOrbisSDK/bin/linux/PkgTool.Core pkg_extractentry "/workspace/$pkg_name" "$icon0_index" "/workspace/_img/$title_id.png"
            echo "Extracted fallback cover from PKG"
        fi
    fi

    echo "========================="
    # Create json entry for the element
    json_entry=$(jq -n --arg title_id "$title_id" --arg region "$region" --arg name "$title" --arg version "$version" \
                      --arg release "$release" --argjson size $size --arg cover_url "$cover_url" \
                      '{title_id: $title_id, region: $region, name: $name, version: $version, release: $release, size: $size, cover_url: $cover_url}')

    case "$category" in
        "gd") 
        echo "CATEGORY: GAME"            
        update_json "$JSON_GAMES" "$pkg_url" "$json_entry"
        cGames=$((cGames + 1))
            ;;
        "gp") 
            echo "CATEGORY: UPDATE"
            update_json "$JSON_UPDATES" "$pkg_url" "$json_entry"
            cUpd=$((cUpd + 1))
            ;;
        "ac") 
            echo "CATEGORY: DLC"
            update_json "$JSON_DLC" "$pkg_url" "$json_entry"
            cDlc=$((cDlc + 1))
            ;;
    esac

    echo "TITLE_ID: $title_id"
    echo "REGION: $region"
    echo "TITLE: $title"
    echo "VERSION: $version"
    echo "RELEASE: $release"
    echo "SIZE: $size"
    echo "PKG_URL: $pkg_url"
    echo "COVER_URL: $cover_url"

   #Remove tmp files
    docker exec "$CONTAINER_NAME" rm -f "$sfo_file" /workspace/tmpfile /workspace/tmpfile1

done < <(find "$INPUT_DIR" -type f -name "*.pkg")

# Stops container
echo "Stopping container..."
docker stop "$CONTAINER_NAME"
echo "========================="
echo "PKGs added to jsons:"
echo "  GAMES: $cGames"
echo "  UPDATES: $cUpd"
echo "  DLCs: $cDlc"
echo ""
echo "Cleaning $JSON_GAMES..."
cleanup_json "$JSON_GAMES"
echo "Cleaning $JSON_UPDATES..."
cleanup_json "$JSON_UPDATES"
echo "Cleaning $JSON_DLC..."
cleanup_json "$JSON_DLC"
echo ""
echo "These are the URLs of the JSONs to set in your FPKGi configuration:" 
echo "$SERVER_URL$JSON_GAMES"
echo "$SERVER_URL$JSON_UPDATES"
echo "$SERVER_URL$JSON_DLC"
echo ""
echo "Processing completed."
