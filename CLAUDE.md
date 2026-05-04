# Project rules

## Pre-commit checks

Before creating any commit, run `bin/rubocop` and resolve every offense. If autocorrect (`bin/rubocop -A`) fixes them, verify the diff is reasonable; otherwise fix manually. Do not commit with rubocop offenses outstanding.
