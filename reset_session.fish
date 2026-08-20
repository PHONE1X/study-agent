#!/usr/bin/env fish
# Archives the current cold-path session (its state file + the Обучение
# folder it points to) and primes a fresh state file so the NEXT cycle starts
# a brand-new session, skipping the already-transcribed backlog instead of
# re-summarizing it from scratch.
#
# Cold path has no concept of "session" tied to start_session.fish/
# stop_session.fish -- it just keeps appending to whatever session was last
# open, even across stop/start cycles hours or days apart. Run this before a
# genuinely new/unrelated study topic so old content doesn't bleed into it.

source (dirname (status --current-filename))/sa_config.fish
set -g TRANSCRIPT_FILE ~/.local/share/study-agent/transcript.log
set -g STATE_FILE ~/.local/share/study-agent/cold_path_state.json
set -g VAULT_DIR $SA_VAULT_DIR
set -g STUDY_DIR $SA_STUDY_DIR
set -g TRASH_DIR $STUDY_DIR/_to_delete

mkdir -p $TRASH_DIR

if test -f $STATE_FILE
    set -l old_session_dir (jq -r '.session_dir // empty' $STATE_FILE)
    if test -n "$old_session_dir"; and test -d "$STUDY_DIR/$old_session_dir"
        mv "$STUDY_DIR/$old_session_dir" $TRASH_DIR/
        echo "Archived old session -- $old_session_dir -> _to_delete/"
    end
    mv $STATE_FILE $TRASH_DIR/cold_path_state-(date "+%H%M%S").json
end

if test -f $TRANSCRIPT_FILE
    set -l total_lines (wc -l < $TRANSCRIPT_FILE | string trim)
    jq -n --argjson last $total_lines '{last_line: $last}' > $STATE_FILE
    echo "Reset done -- next cycle starts a fresh session, skipping the $total_lines already-transcribed lines behind it."
else
    echo "No transcript.log yet -- nothing to skip, next cycle bootstraps from scratch."
end
