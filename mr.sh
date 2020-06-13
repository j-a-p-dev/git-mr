#!/usr/bin/env bash


################################################################################
# Git functions

function git_current_branch
{
    git rev-parse --abbrev-ref HEAD
}

function git_base_branch
{
    # Base branch param
    local base_branch=$BASE_BRANCH

    # Nearest branch in commit history
    if [ -z "$base_branch" ]; then
        # selects only commits with a branch or tag
        # removes current head (and branch)
        # selects only the closest decoration
        # filters out everything but decorations
        # splits decorations
        # ignore "tag: ...", "origin/..." and ".../HEAD"
        # keep only first decoration
        local base_branch=$(git log --decorate --simplify-by-decoration --oneline \
            | grep -v "(HEAD"            \
            | head -n1                   \
            | sed 's/.* (\(.*\)) .*/\1/' \
            | sed -e 's/, /\n/g'         \
            | grep -v 'tag:' | grep -vE '^origin\/' | grep -vE '\/HEAD$' \
            | head -n1)
    fi

    # First possible merge base
    if [ -z "$base_branch" ]; then
        base_branch=$(git show-branch  --merge-base | head -n1)
    fi

    echo $base_branch
}

function git_commits
{
    local current_branch=${1:-$(git_current_branch)}
    local base_branch=${2:-$(git_base_branch)}

    git log --oneline --reverse --no-decorate ${base_branch}..${current_branch}
}


################################################################################
# Misc. utilities

function extract_json_string
{
    local key=$1
    local content=$2

    echo $content \
        | grep -Po '"'${key}'"\s*:\s*"\K.*?[^\\]"' \
        | sed 's/\\"/"/g' \
        | sed 's/"$//'
}

# https://gist.github.com/cdown/1163649
function urlencode
{
    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C

    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done

    LC_COLLATE=$old_lc_collate
}

function echo_error
{
    local orange
    local nocolor

    if which tput > /dev/null 2>&1 && [ ! -z "$TERM" ] && [ $(tput -T$TERM colors) -ge 8 ]; then
        orange='\033[0;33m'
        nocolor='\033[0m'
    fi

    printf "${orange}${1}${nocolor}\n" >&2
}


################################################################################
# Markdown formatting

function markdown_title
{
    local label=$1
    local level=${2:-1}

    for ((i=1; i<=$level; i++)); do
        echo -n '#'
    done

    echo " ${label}"
}

function markdown_link
{
    local label=$1
    local url=$2

    if [ -z "$url" ]; then
        echo "[$label]"
        return
    fi

    echo "[$label]($url)"
}

function markdown_list
{
    local content=$1
    local wrap=$2

    local prefix="* ${wrap}"
    local suffix="${wrap}<br>"

    echo "$content" \
        | sed "s/^/${prefix}/g" \
        | sed "s/$/${suffix}/g"
}


################################################################################
# Jira functions

function jira_ticket_data
{
    if [ -z "$JIRA_USER" ] || [ -z "$JIRA_TOKEN" ] || [ -z "$JIRA_INSTANCE" ]; then return; fi

    local auth_token=$(echo -n ${JIRA_USER}:${JIRA_TOKEN} | base64 -w 0)
    local issue_url="https://${JIRA_INSTANCE}/rest/api/3/issue/${1}?fields=summary"

    curl -Ss -X GET \
        --max-time 5 \
        -H "Authorization: Basic ${auth_token}" \
        -H "Content-Type: application/json" \
        ${issue_url}
}


################################################################################
# Gitlab functions

function gitlab_project_url
{
    if [ -z "$GITLAB_DOMAIN" ] || [ -z "$GITLAB_TOKEN" ]; then return; fi

    local gitlab_remote=$(git remote get-url --push origin)
    local project_url=$(git remote get-url --push origin | sed "s/git\@${GITLAB_DOMAIN}:\(.*\).git/\1/")

    echo $project_url
}

function gitlab_merge_requests
{
    if [ -z "$GITLAB_DOMAIN" ] || [ -z "$GITLAB_TOKEN" ]; then return; fi

    local project_id=$(urlencode $(gitlab_project_url))

    if [ -z "$project_id" ]; then return; fi

    local source_branch=${1:-$(git_current_branch)}

    local gitlab_base_url="https://${GITLAB_DOMAIN}/api/v4"

    local merge_requests=$(curl -Ss -X GET \
        --max-time 3 \
        -H "Private-Token: ${GITLAB_TOKEN}" \
        -H "Content-Type: application/json" \
        "${gitlab_base_url}/projects/${project_id}/merge_requests?state=opened&view=simple&source_branch=${source_branch}")

    local error=$(extract_json_string "error" "${merge_requests}")
    local message=$(extract_json_string "message" "${merge_requests}")

    if [ ! -z "$error" ] || [ ! -z "$message" ]; then
        echo_error "Gitlab error:"
        echo_error "  ${merge_requests}"
        echo_error
        return
    fi

    echo "$merge_requests"
}

function gitlab_merge_request_url
{
    local source_branch=${1:-$(git_current_branch)}
    local merge_requests=${2:-$(gitlab_merge_requests "$source_branch")}

    extract_json_string "web_url" "${merge_requests}"
}

function gitlab_new_merge_request_url
{
    if [ -z "$GITLAB_DOMAIN" ] || [ -z "$GITLAB_TOKEN" ]; then return; fi

    local gitlab_remote=$(git remote get-url --push origin)
    local project_url=$(gitlab_project_url)

    if [ -z "$project_url" ]; then return; fi

    local source_branch=${1:-$(git_current_branch)}
    local target_branch=${2:-$(git_base_branch)}

    local gitlab_mr_url="https://${GITLAB_DOMAIN}/${project_url}/merge_requests/new"

    gitlab_mr_url="${gitlab_mr_url}?"$(urlencode "merge_request[source_branch]")"=${source_branch}"
    gitlab_mr_url="${gitlab_mr_url}&"$(urlencode "merge_request[target_branch]")"=${target_branch}"

    echo $gitlab_mr_url
}


################################################################################
# Merge request

function guess_issue_code
{
    if [ -z "$JIRA_CODE_PATTERN" ]; then
        echo_error "JIRA_CODE_PATTERN not set"
        return
    fi

    local current_branch=$(git_current_branch)

    echo "${current_branch}" | grep -iEo $JIRA_CODE_PATTERN | tail -n1
}

function mr_title
{
    local current_branch=${1:-$(git_current_branch)}

    if [ -z "$ISSUE_CODE" ]; then
        echo $current_branch
        return
    fi

    local issue_content=$(jira_ticket_data $ISSUE_CODE)

    local issue_key=$(extract_json_string "key" "$issue_content")
    local issue_title=$(extract_json_string "summary" "$issue_content")

    if [ -z "$issue_key" ]; then
        issue_key=${ISSUE_CODE^^}
    fi

    if [ -z "$issue_title" ]; then
        echo_error "Unable to get issue title from Jira"
        if [ ! -z "$issue_content" ]; then
            echo_error "  $issue_content"
        fi

        echo $issue_key
        return
    fi

    issue_url="https://${JIRA_INSTANCE}/browse/${issue_key}"

    echo $(markdown_link "${issue_key} ${issue_title}" "$issue_url")
}

function mr_description
{
    local current_branch=${1:-$(git_current_branch)}
    local base_branch=${2:-$(git_base_branch)}

    local title=$(mr_title "$current_branch")
    local commits=$(git_commits "$current_branch" "$base_branch")

    cat << EOF

--------------------------------------------------------------------------------
$(markdown_title "$title")


## Commits

$(markdown_list "$commits" "**")

--------------------------------------------------------------------------------

EOF
}

function mr_actions
{
    local current_branch=${1:-$(git_current_branch)}
    local base_branch=${2:-$(git_base_branch)}

    local merge_requests=$(gitlab_merge_requests "$current_branch")

    local current_mr_url=$(gitlab_merge_request_url ${current_branch} "$merge_requests")

    if [ ! -z "${current_mr_url}" ]; then
        cat << EOF
Merge request:

  ${current_mr_url}

EOF
    return
    fi

    local new_mr_url=$(gitlab_new_merge_request_url ${current_branch} ${base_branch})

cat << EOF
To create a new merge request:

  ${new_mr_url}

EOF
}

function print_mr
{
    local current_branch=${1:-$(git_current_branch)}
    local base_branch=${2:-$(git_base_branch)}

    mr_description $current_branch $base_branch
    mr_actions     $current_branch $base_branch
}

function usage
{
    cat << EOF

USAGE

    mr [issue_code] [base_branch]

INSTALLATION

    As a standalone script:

        alias mr=/path/to/mr.sh

    As a git alias:

        Define this alias in your .gitconfig:

        [alias]
            mr = "!bash /path/to/mr.sh"

CONFIGURATION

    You need to configure the following environment variables:

        export JIRA_USER="user.name@mycompany.com"
        export JIRA_INSTANCE="mycompany.atlassian.net"
        export JIRA_TOKEN="abcdefghijklmnopqrstuvwx"
        export JIRA_CODE_PATTERN="XY-[0-9]+"

        export GITLAB_DOMAIN="myapp.gitlab.com"
        export GITLAB_TOKEN="Zyxwvutsrqponmlkjihg"

    To create a Jira API Token, go to: https://id.atlassian.com/manage-profile/security/api-tokens
    (Account Settings -> Security -> API Token -> Create and manage API tokens)

    To create a Gitlab API Token, go to: https://myapp.gitlab.com/profile/personal_access_tokens<br>
    (Settings -> Access Tokens)

EOF
}


################################################################################
# Run

ISSUE_CODE=${1:-$(guess_issue_code)}
BASE_BRANCH=$2

if [ -z "$JIRA_USER" ];     then echo_error "JIRA_USER not set";          fi
if [ -z "$JIRA_INSTANCE" ]; then echo_error "JIRA_INSTANCE not set";      fi
if [ -z "$JIRA_TOKEN" ];    then echo_error "JIRA_TOKEN not set";         fi
if [ -z "$ISSUE_CODE" ];    then echo_error "Unable to guess issue code"; fi
if [ -z "$GITLAB_DOMAIN" ]; then echo_error "GITLAB_DOMAIN not set";      fi
if [ -z "$GITLAB_TOKEN" ];  then echo_error "GITLAB_TOKEN not set";       fi

case $1 in
    help) usage ;;
    *)    print_mr ;;
esac
