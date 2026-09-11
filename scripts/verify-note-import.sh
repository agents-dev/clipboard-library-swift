#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERIFY_GITHUB_IMPORT=1 swift test --filter 'GitHubSkillTests|NoteFileTests|NoteViewTests'
